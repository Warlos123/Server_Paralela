#include "../includes/work_queue.h"
#include <stdlib.h>
#include <stdio.h>

int wq_init(work_queue_t *q, int capacity){
   q->file_descriptors = malloc(capacity * sizeof(int));

   if(q->file_descriptors == NULL){
        fprintf(stderr,"failure, dropping connection\n");
        return -1; 
   }

   q->capacity = capacity; 
   q->head = 0; 
   q->tail = 0;
   q->count = 0; 
   q->closed = 0; 

   if(pthread_mutex_init(&q->mutex,NULL) != 0){
    free(q->file_descriptors);
    return -1;
   }

   if(pthread_cond_init(&q->not_empty,NULL) != 0){
    pthread_mutex_destroy(&q->mutex);
    free(q->file_descriptors);
    return -1;
   }

   if(pthread_cond_init(&q->not_full,NULL) != 0){
    pthread_mutex_destroy(&q->mutex);
    pthread_cond_destroy(&q->not_empty); 
    free(q->file_descriptors);
    return -1;
   }

   return 0; 
}


int wq_push(work_queue_t *q, int file_descriptor){
    pthread_mutex_lock(&q->mutex);

    while(q->count == q->capacity && q->closed == 0){
        pthread_cond_wait(&q->not_full, &q->mutex);
    } 
    if(q->closed == 1 ){
        pthread_mutex_unlock(&q->mutex);
        return -1; 
    }

    q->file_descriptors[q->tail] = file_descriptor;
    q->tail = (q->tail + 1) % q->capacity;
    q->count++; 
    pthread_cond_signal(&q->not_empty);

    pthread_mutex_unlock(&q->mutex);
    return 0; 
}


int wq_pop(work_queue_t *q, int *out_file_descriptor){
    pthread_mutex_lock(&q->mutex);
    while(q->count == 0 && q->closed == 0){
        pthread_cond_wait(&q->not_empty, &q->mutex);
    }
    if(q->count == 0 && q->closed == 1 ){
        pthread_mutex_unlock(&q->mutex);
        return -1; 
    }

    *out_file_descriptor = q->file_descriptors[q->head];
    q->head = (q->head + 1 ) % q->capacity;
    q->count--; 
    pthread_cond_signal(&q->not_full);

    pthread_mutex_unlock(&q->mutex);
    return 0;
}

void wq_close(work_queue_t *q){
    pthread_mutex_lock(&q->mutex);
    q->closed = 1;
    pthread_cond_broadcast(&q->not_empty);  //wake up consumers 
    pthread_cond_broadcast(&q->not_full);  //wake up producer 
    pthread_mutex_unlock(&q->mutex);
}

void wq_destroy(work_queue_t *q){
    pthread_cond_destroy(&q->not_full);
    pthread_cond_destroy(&q->not_empty);
    pthread_mutex_destroy(&q->mutex);
    free(q->file_descriptors); 
}