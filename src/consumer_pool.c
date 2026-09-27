#include "../includes/consumer_pool.h"
#include "../includes/net_util.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static void *consumer_loop(void *arg){
    consumer_pool_t *pool = arg; 
    int file_descriptor; 
    int ext = 0; 
    while(ext != 1){
        if(wq_pop(pool->queue, &file_descriptor) == -1){
            ext = 1; 
        }else{ 
            pthread_mutex_lock(&pool->request_mutex);  
            unsigned long id = pool->requests_served;
            pool->requests_served++;
            pthread_mutex_unlock(&pool->request_mutex);
            if(nu_drain_request(file_descriptor) > 0){
                (void)nu_send_response(file_descriptor, id);
            }
            close(file_descriptor);   
        }
    }

    return NULL; 
}


int cp_init(consumer_pool_t *pool, int count, work_queue_t *q){
    pool->threads = malloc(count*sizeof(pthread_t));
    if(pool->threads == NULL ){
        fprintf(stderr,"failure, dropping connection\n");
        return -1;
    }

    pool->queue = q; 
    pool->count = count; 
    pool->requests_served = 0;
    
    
    if(pthread_mutex_init(&pool->request_mutex,NULL) != 0){
        free(pool->threads);
        return -1;
    }

    for(int i = 0; i < count; i++){
        int result = pthread_create(&pool->threads[i], NULL, consumer_loop, pool);
        if (result != 0)
        {
            fprintf(stderr, "pthread_create failed %s\n", strerror(result));
            pool->count = i;
            break;
        }
    }
    if(pool->count == 0){
        pthread_mutex_destroy(&pool->request_mutex);
        free(pool->threads);
        return -1;
    }

    return 0; 
}

void cp_destroy(consumer_pool_t *pool){
    for(int i = 0; i < pool->count; i++){
        pthread_join(pool->threads[i], NULL);
    }
    free(pool->threads);
    pthread_mutex_destroy(&pool->request_mutex);
}