#!/usr/bin/env python3
"""
Analiza results/benchmark_results.csv generado por benchmark.sh.

Uso:
    python3 analyze_results.py results/benchmark_results.csv

Imprime una tabla por escenario (promedio ± desviación estándar de las
corridas) y escribe results/summary.csv con los promedios, listo para
graficar en Excel/Sheets.
"""

import csv
import os
import sys
from collections import defaultdict
from statistics import mean, stdev

SERVER_ORDER = ["unsafe", "safe", "semaphore", "producer_consumer"]
BASELINE = "safe"

METRICS = [
    # (columna del CSV, nombre corto, decimales)
    ("elapsed_s", "tiempo_s", 3),
    ("throughput_req_s", "req_s", 1),
    ("client_completed", "completados", 0),
    ("server_lost", "perdidos_srv", 0),
    ("peak_rss_kb", "rss_kb", 0),
    ("peak_threads", "hilos_max", 0),
]


def to_number(text):
    if text is None or text == "" or text == "NA":
        return None
    return float(text)


def load(path):
    groups = defaultdict(list)
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            key = (int(row["threads"]), int(row["requests_per_thread"]), row["server"])
            groups[key].append(row)
    return groups


def summarize(values):
    clean = []
    for i in range(len(values)):
        if values[i] is not None:
            clean.append(values[i])
    if len(clean) == 0:
        return None, None
    if len(clean) == 1:
        return clean[0], 0.0
    return mean(clean), stdev(clean)


def fmt(avg, sd, decimals):
    if avg is None:
        return "NA"
    return f"{avg:.{decimals}f} ± {sd:.{decimals}f}"


def main():
    if len(sys.argv) != 2:
        print("uso: python3 analyze_results.py results/benchmark_results.csv")
        sys.exit(1)

    path = sys.argv[1]
    groups = load(path)
    if len(groups) == 0:
        print("el CSV está vacío")
        sys.exit(1)

    scenarios = sorted({(k[0], k[1]) for k in groups})
    summary_rows = []

    for s in range(len(scenarios)):
        threads, per_thread = scenarios[s]
        total = threads * per_thread
        print()
        print(f"=== {threads} hilos x {per_thread} req = {total} requests ===")
        header = f"{'servidor':<18}"
        for m in range(len(METRICS)):
            header += f" | {METRICS[m][1]:>18}"
        header += f" | {'vs ' + BASELINE:>9}"
        print(header)
        print("-" * len(header))

        baseline_tp = None
        baseline_rows = groups.get((threads, per_thread, BASELINE))
        if baseline_rows is not None:
            tps = []
            for r in range(len(baseline_rows)):
                tps.append(to_number(baseline_rows[r]["throughput_req_s"]))
            baseline_tp, _ = summarize(tps)

        for i in range(len(SERVER_ORDER)):
            server = SERVER_ORDER[i]
            rows = groups.get((threads, per_thread, server))
            if rows is None:
                continue

            line = f"{server:<18}"
            summary = {
                "server": server,
                "threads": threads,
                "requests_per_thread": per_thread,
                "total_sent": total,
                "runs": len(rows),
            }
            throughput_avg = None

            for m in range(len(METRICS)):
                column, short, decimals = METRICS[m]
                values = []
                for r in range(len(rows)):
                    values.append(to_number(rows[r][column]))
                avg, sd = summarize(values)
                line += f" | {fmt(avg, sd, decimals):>18}"
                if avg is not None:
                    avg = round(avg, 4)
                    sd = round(sd, 4)
                summary[short + "_avg"] = avg
                summary[short + "_sd"] = sd
                if column == "throughput_req_s":
                    throughput_avg = avg

            if server == BASELINE or baseline_tp is None or throughput_avg is None:
                delta = "base"
            else:
                delta = f"{(throughput_avg - baseline_tp) / baseline_tp * 100:+.1f}%"
            line += f" | {delta:>9}"
            print(line)
            summary_rows.append(summary)

    out_path = os.path.join(os.path.dirname(path) or ".", "summary.csv")
    with open(out_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(summary_rows[0].keys()))
        writer.writeheader()
        for i in range(len(summary_rows)):
            writer.writerow(summary_rows[i])

    print()
    print("perdidos_srv = accepted - served según el propio servidor (la condición de carrera).")
    print("completados  = respuestas que recibió el cliente.")
    print(f"vs {BASELINE}     = diferencia de throughput contra la versión con mutex.")
    print(f"Promedios guardados en {out_path}")


if __name__ == "__main__":
    main()
