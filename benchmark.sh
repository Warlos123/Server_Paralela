#!/usr/bin/env bash
#
# Benchmark de las 4 versiones del mini server:
#   unsafe            thread-per-connection, sin sincronización
#   safe              thread-per-connection, mutex
#   semaphore         thread-per-connection, semáforo
#   producer_consumer pool fijo de consumers + cola acotada
#
# Se corre desde la raíz del proyecto (donde están src/ e includes/):
#   ./benchmark.sh
#
# Variables opcionales:
#   SERVER_CORES=0-3 CLIENT_CORES=10,11 RUNS=3 PORT=8080 ./benchmark.sh
#
# Salida: results/benchmark_results.csv (una fila por corrida)
#

set -euo pipefail

SERVER_CORES="${SERVER_CORES:-0-3}"
CLIENT_CORES="${CLIENT_CORES:-10,11}"
RUNS="${RUNS:-3}"
PORT="${PORT:-8080}"

BUILD_DIR="build"
RESULTS_DIR="results"
RESULTS_FILE="$RESULTS_DIR/benchmark_results.csv"
CFLAGS="-Wall -Wextra -pthread"

# Escenarios "hilos:requests_por_hilo"
#   Los dos últimos son de estrés: 500 mil y 1 millón de requests.
# Se pueden elegir desde la línea de comandos, por ejemplo:
#   SCENARIOS="100:5000 100:10000" ./benchmark.sh
DEFAULT_SCENARIOS="10:150 20:150 50:100 100:50 100:5000 100:10000"
read -r -a SCENARIOS <<< "${SCENARIOS:-$DEFAULT_SCENARIOS}"
SERVERS=("unsafe" "safe" "semaphore" "producer_consumer")

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Compilación. Si algo falla, el script se detiene (no corre binarios viejos).
# ---------------------------------------------------------------------------
compile_all() {
    mkdir -p "$BUILD_DIR"
    rm -f "$BUILD_DIR"/*

    log "Compilando..."
    gcc $CFLAGS -o "$BUILD_DIR/server_unsafe"            src/server_unsafe.c    src/net_util.c
    gcc $CFLAGS -o "$BUILD_DIR/server_safe"              src/server_safe.c      src/net_util.c
    gcc $CFLAGS -o "$BUILD_DIR/server_semaphore"         src/server_semaphore.c src/net_util.c
    gcc $CFLAGS -o "$BUILD_DIR/server_producer_consumer" src/producer.c src/consumer_pool.c src/work_queue.c src/net_util.c
    gcc $CFLAGS -o "$BUILD_DIR/load_client"              src/load_client.c
    log "Compilación OK"
}

# ---------------------------------------------------------------------------
# Espera a que el servidor imprima "listening" (máx. 5 s)
# ---------------------------------------------------------------------------
wait_for_server() {
    local pid=$1
    local log_file=$2
    for i in $(seq 1 50); do
        if ! kill -0 "$pid" 2>/dev/null; then
            cat "$log_file" >&2
            die "el servidor murió al arrancar"
        fi
        if grep -q "listening" "$log_file" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
    done
    die "el servidor no arrancó en 5 s"
}

# ---------------------------------------------------------------------------
# Muestrea /proc/<pid>/status mientras corre el cliente y guarda
# el máximo de hilos vivos. Corre en background.
# ---------------------------------------------------------------------------
sample_threads() {
    local pid=$1
    local out_file=$2
    local max=0
    while kill -0 "$pid" 2>/dev/null; do
        local n
        n=$(awk '/^Threads:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo 0)
        if [ -n "$n" ] && [ "$n" -gt "$max" ]; then
            max=$n
            echo "$max" > "$out_file"
        fi
        sleep 0.02
    done
}

# ---------------------------------------------------------------------------
# Detiene el servidor con SIGINT (no SIGTERM: solo SIGINT imprime el
# resumen accepted/served/lost). Reintenta por si la señal cae en un
# hilo worker y accept() no se interrumpe.
# ---------------------------------------------------------------------------
stop_server() {
    local pid=$1
    for i in $(seq 1 20); do
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        kill -INT "$pid" 2>/dev/null || true
        sleep 0.5
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
        log "  AVISO: el servidor no respondió a SIGINT, se mató con SIGKILL"
    fi
    wait "$pid" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Una corrida
# ---------------------------------------------------------------------------
run_one() {
    local server=$1
    local threads=$2
    local per_thread=$3
    local run=$4
    local total=$((threads * per_thread))

    local server_log="$RESULTS_DIR/logs/${server}_${threads}x${per_thread}_run${run}.log"
    local threads_file
    threads_file=$(mktemp)
    echo 0 > "$threads_file"

    taskset -c "$SERVER_CORES" "./$BUILD_DIR/server_$server" "$PORT" > "$server_log" 2>&1 &
    local server_pid=$!
    wait_for_server "$server_pid" "$server_log"

    sample_threads "$server_pid" "$threads_file" &
    local sampler_pid=$!

    local t_start t_end
    t_start=$(date +%s%N)
    local client_out
    client_out=$(taskset -c "$CLIENT_CORES" "./$BUILD_DIR/load_client" 127.0.0.1 "$PORT" "$threads" "$per_thread")
    t_end=$(date +%s%N)

    # Pico de memoria residente (VmHWM) antes de apagar el servidor
    local peak_rss_kb
    peak_rss_kb=$(awk '/^VmHWM:/ {print $2}' "/proc/$server_pid/status" 2>/dev/null || echo 0)

    stop_server "$server_pid"
    wait "$sampler_pid" 2>/dev/null || true
    local peak_threads
    peak_threads=$(cat "$threads_file")
    rm -f "$threads_file"

    local completed
    completed=$(echo "$client_out" | awk '/requests completed:/ {print $NF}')
    completed=${completed:-0}

    local accepted served lost
    accepted=$(awk '/^accepted:/ {print $2}' "$server_log")
    served=$(awk '/^served:/ {print $2}' "$server_log")
    lost=$(awk '/^lost:/ {print $2}' "$server_log")
    accepted=${accepted:-NA}
    served=${served:-NA}
    lost=${lost:-NA}

    local elapsed throughput
    elapsed=$(awk -v a="$t_start" -v b="$t_end" 'BEGIN {printf "%.4f", (b - a) / 1e9}')
    throughput=$(awk -v c="$completed" -v e="$elapsed" 'BEGIN {printf "%.2f", c / e}')

    echo "$server,$threads,$per_thread,$total,$run,$elapsed,$completed,$((total - completed)),$throughput,$accepted,$served,$lost,$peak_rss_kb,$peak_threads" >> "$RESULTS_FILE"

    printf "  %-18s %4dx%-4d run %d | %7.3f s | %9.2f req/s | client %5d/%-5d | server lost %-4s | RSS %6s KB | hilos %s\n" \
        "$server" "$threads" "$per_thread" "$run" "$elapsed" "$throughput" "$completed" "$total" "$lost" "$peak_rss_kb" "$peak_threads"
}

# ---------------------------------------------------------------------------
main() {
    [ -d src ] || die "correlo desde la raíz del proyecto (no encuentro src/)"
    command -v taskset > /dev/null || die "falta taskset (paquete util-linux)"

    compile_all

    mkdir -p "$RESULTS_DIR/logs"
    # Si el CSV ya existe se agregan filas al final (no se borra lo anterior).
    # Para empezar de cero: rm -rf results
    if [ ! -f "$RESULTS_FILE" ]; then
        echo "server,threads,requests_per_thread,total_sent,run,elapsed_s,client_completed,client_failed,throughput_req_s,server_accepted,server_served,server_lost,peak_rss_kb,peak_threads" > "$RESULTS_FILE"
    else
        log "Agregando filas a $RESULTS_FILE existente"
    fi

    log "Servidor en cores $SERVER_CORES, cliente en cores $CLIENT_CORES, $RUNS corridas por escenario"

    # Se intercalan los servidores dentro de cada corrida para que
    # cualquier variación de la máquina afecte a todos por igual.
    for scenario in "${SCENARIOS[@]}"; do
        local threads=${scenario%%:*}
        local per_thread=${scenario##*:}
        log "Escenario ${threads} hilos x ${per_thread} req = $((threads * per_thread)) requests"
        for run in $(seq 1 "$RUNS"); do
            for server in "${SERVERS[@]}"; do
                run_one "$server" "$threads" "$per_thread" "$run"
            done
        done
    done

    log "Listo. Resultados en $RESULTS_FILE"
    log "Análisis: python3 analyze_results.py $RESULTS_FILE"
}

main "$@"
