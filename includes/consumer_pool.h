#ifndef MINI_SERVER_CONSUMER_POOL_H
#define MINI_SERVER_CONSUMER_POOL_H
#include"work_queue.h"
#include <pthread.h>

typedef struct{
    pthread_t *threads; 
    int count; 
    work_queue_t *queue; 
    unsigned long requests_served; 
    pthread_mutex_t request_mutex; 
}consumer_pool_t;  


int cp_init(consumer_pool_t *pool, int count, work_queue_t *q);

void cp_destroy(consumer_pool_t *pool);

#endif 