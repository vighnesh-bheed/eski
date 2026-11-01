#ifndef ESKI_MODULE_ALLOC_H
#define ESKI_MODULE_ALLOC_H
#include <stddef.h>
void *es_module_malloc(size_t size);
void *es_module_realloc(void *ptr, size_t size);
void es_module_free(void *ptr);
_Noreturn void es_module_abort(void);
#define malloc es_module_malloc
#define realloc es_module_realloc
#define free es_module_free
#define abort es_module_abort
#endif
