#ifndef OSWIND_PII_RUNTIME_H
#define OSWIND_PII_RUNTIME_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct OSWPiiSession OSWPiiSession;
/* Caller supplies a verified, live descriptor path and exact pinned ONNX bytes.
 * No download, custom operator registration, profiling or provider retry.
 * Destroy only after synchronous Run returns; Swift owner serializes/join-drains.
 * Errors never contain the original input text (only integer tensors cross ABI).
 */
int OSWPiiCreate(const char* library_descriptor_path,const void* model,size_t model_bytes,
                 int coreml,OSWPiiSession** result,char* error,size_t error_capacity);
int OSWPiiRun(OSWPiiSession* session,const int64_t* ids,const int64_t* attention,
              const int64_t* words_mask,size_t token_count,int64_t word_count,
              float* output,size_t output_count,char* error,size_t error_capacity);
void OSWPiiDestroy(OSWPiiSession* session);
#ifdef __cplusplus
}
#endif
#endif
