#ifndef MINI_SERVER_WORK_QUEUE_H
#define MINI_SERVER_WORK_QUEUE_H

#include <pthread.h>

typedef struct  
{
    int *file_descriptors; 
    int capacity; 
    int head; 
    int tail;
    int count; 
    pthread_mutex_t mutex; 
    pthread_cond_t not_empty; 
    pthread_cond_t not_full; 
    int closed; 
    
}work_queue_t;

int wq_init(work_queue_t *q, int capacity); 

int wq_pop(work_queue_t *q, int *out_file_descriptor); 

int wq_push(work_queue_t *q, int file_descriptor);

void wq_close(work_queue_t *q);

void wq_destroy(work_queue_t *q);


#endif