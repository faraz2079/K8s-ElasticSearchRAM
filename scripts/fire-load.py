#!/usr/bin/env python3
import os, sys, time, random, threading, argparse, signal, subprocess
from datetime import datetime
from pathlib import Path

try:
    from elasticsearch import Elasticsearch, helpers as es_helpers
    from faker import Faker
except ImportError:
    print("Missing deps. Run: pip install 'elasticsearch>=8,<9' faker requests")
    sys.exit(1)

def load_dotenv(path):
    env = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, _, v = line.partition("=")
                    env[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return env

repo_root = Path(__file__).resolve().parent.parent
dotenv = load_dotenv(repo_root / ".env")

parser = argparse.ArgumentParser(description="Dynamic ES load generator")
parser.add_argument("--host",       default=None)
parser.add_argument("--target-ram", type=int, default=None)
parser.add_argument("--duration",   type=int, default=None, help="minutes")
parser.add_argument("--threads",    type=int, default=None)
parser.add_argument("--yes",        action="store_true")
args = parser.parse_args()

def prompt_int(msg, lo, hi, default):
    while True:
        raw = input(msg + " [" + str(default) + "]: ").strip()
        if not raw: return default
        try:
            v = int(raw)
            if lo <= v <= hi: return v
            print("  Enter " + str(lo) + "-" + str(hi))
        except ValueError:
            print("  Enter a number")

es_host        = args.host       or dotenv.get("ES_HOST") or "http://localhost:30920"
target_ram_pct = args.target_ram or prompt_int("RAM % target", 10, 95, 75)
duration_min   = args.duration   or prompt_int("Duration in minutes", 1, 480, 30)
n_threads      = args.threads    or prompt_int("Loader threads", 1, 32, 4)

print("\nHost: " + es_host + "  |  RAM target: " + str(target_ram_pct) + "%  |  " + str(duration_min) + " min  |  " + str(n_threads) + " threads")
if not args.yes:
    if input("Start? [Y/n]: ").strip().lower() not in ("", "y", "yes"):
        print("Aborted."); sys.exit(0)

es   = Elasticsearch(es_host, request_timeout=30, max_retries=3, retry_on_timeout=True)
fake = Faker()

def wait_for_es():
    print("\nConnecting to " + es_host + "...")
    for i in range(20):
        try:
            if es.ping():
                h = es.cluster.health()
                print("  Connected. Cluster: " + h["status"] + "\n")
                return
        except Exception:
            pass
        print("  Attempt " + str(i+1) + "/20...")
        time.sleep(5)
    print("ERROR: Cannot connect to " + es_host)
    sys.exit(1)

wait_for_es()

_ram_pct = 0.0
_ram_used = 0.0
_ram_total = 0.0

def refresh_ram():
    global _ram_pct, _ram_used, _ram_total
    try:
        s = es.nodes.stats(metric="os")
        for n in s["nodes"].values():
            tot  = n["os"]["mem"]["total_in_bytes"]
            free = n["os"]["mem"]["free_in_bytes"]
            _ram_total = tot / 1024**3
            _ram_used  = (tot - free) / 1024**3
            _ram_pct   = (tot - free) / tot * 100
            break
    except Exception:
        pass

def ram_monitor_loop(stop):
    while not stop.is_set():
        refresh_ram()
        time.sleep(3)

_throttle = 1.0
_tlock    = threading.Lock()

def update_throttle():
    global _throttle
    with _tlock:
        _throttle = max(0.05, min(1.0, _throttle + (target_ram_pct - _ram_pct) * 0.04))

N_IDX   = 8
IDX_PFX = "stress"

def ensure_indices():
    for i in range(N_IDX):
        idx = IDX_PFX + "-" + str(i)
        if not es.indices.exists(index=idx):
            es.indices.create(index=idx, body={
                "settings": {"number_of_shards": 1, "number_of_replicas": 0, "refresh_interval": "5s"},
                "mappings": {"properties": {
                    "action":      {"type": "text", "fields": {"keyword": {"type": "keyword"}}},
                    "region":      {"type": "text", "fields": {"keyword": {"type": "keyword"}}},
                    "category":    {"type": "text", "fields": {"keyword": {"type": "keyword"}}},
                    "price":       {"type": "float"},
                    "score":       {"type": "float"},
                    "user_id":     {"type": "integer"},
                    "item_id":     {"type": "integer"},
                    "description": {"type": "text"},
                    "tags":        {"type": "keyword"},
                    "timestamp":   {"type": "date"},
                }}
            })
    print("Indices ready: " + IDX_PFX + "-0.." + IDX_PFX + "-" + str(N_IDX-1))

ensure_indices()

def rdoc(idx):
    return {"_index": idx, "_source": {
        "timestamp":   datetime.utcnow().isoformat(),
        "user_id":     random.randint(1, 200000),
        "session_id":  fake.uuid4(),
        "action":      random.choice(["view", "click", "purchase", "search", "refund"]),
        "item_id":     random.randint(1, 100000),
        "price":       round(random.uniform(0.99, 1999.99), 2),
        "category":    fake.word(),
        "description": fake.paragraph(nb_sentences=random.randint(2, 8)),
        "tags":        [fake.word() for _ in range(random.randint(2, 8))],
        "ip":          fake.ipv4(),
        "region":      fake.country_code(),
        "score":       random.random(),
    }}

def run_queries():
    idx = IDX_PFX + "-*"
    queries = [
        {"size": 0, "aggs": {
            "by_action":   {"terms": {"field": "action.keyword",   "size": 100}},
            "by_region":   {"terms": {"field": "region.keyword",   "size": 200}},
            "by_category": {"terms": {"field": "category.keyword", "size": 500}},
            "avg_price":   {"avg":   {"field": "price"}},
            "price_pct":   {"percentiles": {"field": "price", "percents": [10,25,50,75,90,95,99]}},
            "score_stats": {"extended_stats": {"field": "score"}},
        }},
        {"size": 0, "aggs": {
            "by_user": {"terms": {"field": "user_id", "size": 10000}},
        }},
        {"size": 0, "aggs": {
            "by_region": {"terms": {"field": "region.keyword", "size": 50},
                "aggs": {
                    "avg_price": {"avg": {"field": "price"}},
                    "by_action": {"terms": {"field": "action.keyword", "size": 10}},
                }
            }
        }},
        {"size": 100, "query": {"bool": {
            "must":   [{"match": {"description": fake.word()}}],
            "filter": [{"range": {"price": {"gte": 10, "lte": 500}}}],
        }}},
        {"size": 500, "from": random.randint(0, 50000), "query": {"match_all": {}}},
    ]
    for body in queries:
        try:
            es.search(index=idx, body=body, request_timeout=30)
        except Exception:
            pass

_stop       = threading.Event()
_docs_total = 0
_dlock      = threading.Lock()
BASE_DOCS   = 5000

def worker(wid):
    global _docs_total
    idx = IDX_PFX + "-" + str(wid % N_IDX)
    while not _stop.is_set():
        with _tlock: t = _throttle
        n = max(200, int(BASE_DOCS * t * random.uniform(0.7, 1.3)))
        try:
            ok, _ = es_helpers.bulk(es, (rdoc(idx) for _ in range(n)),
                                    chunk_size=500, raise_on_error=False)
            with _dlock: _docs_total += ok
        except Exception:
            pass
        run_queries()
        _stop.wait(random.uniform(0.02, 0.15) * (2 - t))

def progress_loop(end_time):
    last = 0
    while not _stop.is_set() and time.time() < end_time:
        elapsed = time.time() - start_t
        with _dlock: total = _docs_total
        with _tlock: t     = _throttle
        rate  = (total - last) / 5
        last  = total
        arrow = "^" if _ram_pct < target_ram_pct - 2 else ("v" if _ram_pct > target_ram_pct + 2 else "=")
        pct   = min(1.0, elapsed / (duration_min * 60))
        bar   = "#" * int(20 * pct) + "-" * (20 - int(20 * pct))
        left  = max(0, end_time - time.time())
        sys.stdout.write(
            "\r[" + bar + "] " +
            str(round(elapsed/60, 1)) + "/" + str(duration_min) + "min  " +
            "RAM:" + str(round(_ram_pct, 1)) + "%/" + str(target_ram_pct) + "%" + arrow + " (" +
            str(round(_ram_used, 1)) + "/" + str(round(_ram_total, 1)) + "GiB)  " +
            "throttle:" + str(round(t, 2)) + "  " +
            "docs:" + str(total) + " (" + str(int(rate)) + "/s)  " +
            "left:" + str(round(left/60, 1)) + "min   "
        )
        sys.stdout.flush()
        time.sleep(5)
    print()

def cleanup_indices():
    print("Deleting stress indices to release segment memory...")
    for i in range(N_IDX):
        try:
            es.indices.delete(index=IDX_PFX + "-" + str(i), ignore_unavailable=True)
        except Exception as e:
            print("  cleanup failed for " + IDX_PFX + "-" + str(i) + ": " + str(e))
    print("Indices deleted. Scale ES to 0 to fully release heap: kubectl scale statefulset elasticsearch -n es-stress --replicas=0")

def _sigint(s, f):
    print("\nStopping...")
    _stop.set()

signal.signal(signal.SIGINT, _sigint)

start_t  = time.time()
end_time = start_t + duration_min * 60

_ram_stop = threading.Event()
threading.Thread(target=ram_monitor_loop, args=(_ram_stop,), daemon=True).start()
time.sleep(1)
refresh_ram()

def _throttle_loop():
    while not _stop.is_set():
        update_throttle()
        time.sleep(3)

threading.Thread(target=_throttle_loop, daemon=True).start()

print("Starting " + str(n_threads) + " workers...\n")
for i in range(n_threads):
    threading.Thread(target=worker, args=(i,), daemon=True).start()
    time.sleep(0.1)

progress_loop(end_time)
_stop.set()
_ram_stop.set()

print("\nDone. " + str(round((time.time()-start_t)/60, 1)) + " min | " + str(_docs_total) + " docs | final RAM " + str(round(_ram_pct, 1)) + "%")
cleanup_indices()

stop_sh = repo_root / "stop.sh"
if stop_sh.exists():
    print("\nScaling ES to 0 to release heap...")
    subprocess.run(["bash", str(stop_sh)], check=False)
