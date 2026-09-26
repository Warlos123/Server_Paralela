#include "../includes/net_util.h"
#include"../includes/consumer_pool.h"
#include "../includes/work_queue.h"
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static volatile sig_atomic_t g_running = 1;

static unsigned long g_requests_served = 0;

#define DEFAULT_PORT 8080
#define LISTEN_BACKLOG 64
#define DRAIN_SECONDS 1
#define QUEUE_CAPACITY 64
#define CONSUMER_COUNT 8

static void on_sigint(int signum)
{
    (void)signum;
    g_running = 0;
}

static int install_signal_handlers(void)
{
    struct sigaction sa;

    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_sigint;

    if (sigaction(SIGINT, &sa, NULL) < 0)
    {
        perror("sigaction");
        return -1;
    }

    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_sigint;

    if (sigaction(SIGPIPE, &sa, NULL) < 0)
    {
        perror("sigaction");
        return -1;
    }

    return 0;
}

static unsigned short parse_port(int argc, char **argv)
{
    if (argc < 2)
    {
        return DEFAULT_PORT;
    }

    char *end = NULL;
    errno = 0;
    long value = strtol(argv[1], &end, 10);

    if (errno != 0 || end == argv[1] || *end != '\0' ||
        value <= 0 || value > 65535) {
        fprintf(stderr, "invalid port '%s', using %d\n", argv[1], DEFAULT_PORT);
        return DEFAULT_PORT;
        }

    return (unsigned short)value;
}

int main(int argc, char **argv){
    if(install_signal_handlers() < 0){
        return EXIT_FAILURE;
    }

    unsigned short port = parse_port(argc,argv);

    int listen_file_desciptor = nu_listen(port, LISTEN_BACKLOG);

    if(listen_file_desciptor < 0){
        return EXIT_FAILURE;
    }

    printf("listening on port %u — Ctrl-C to stop\n", port);
    fflush(stdout);

    work_queue_t workQueue; 
    wq_init(&workQueue, QUEUE_CAPACITY);

    consumer_pool_t consumerPool;
    cp_init(&consumerPool, CONSUMER_COUNT ,&workQueue);

    while(g_running){
        int client_file_descriptor = accpet(listen_file_desciptor,NULL,NULL);
        if(client_file_descriptor < 0){
            if(errno == EINTR){
                continue;
            }
            perror(accept);
            break;
        }
        // push
         
    }

    wq_close(&workQueue);
    cp_destroy(&consumerPool);
    wq_destroy(&workQueue);

    //print stats

    return 0;
}