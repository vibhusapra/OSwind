#include "PIIRuntime.h"
#include "onnxruntime_c_api.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <memory>
#include <stdexcept>
#include <string>

static_assert(ORT_API_VERSION == 24, "Pinned ONNX Runtime C API changed");
static void require(bool condition,const char* message) {
    if (!condition) throw std::runtime_error(message);
}
static void fail(char* output,size_t capacity,const char* message) {
    if (output && capacity) std::snprintf(output,capacity,"%s",message);
}
struct OSWPiiSession {
    void* library=nullptr;
    const OrtApi* api=nullptr;
    OrtEnv* environment=nullptr;
    OrtSession* session=nullptr;
    OrtMemoryInfo* memory=nullptr;
    bool coreml=false;
    ~OSWPiiSession() {
        if (session) api->ReleaseSession(session);
        if (memory) api->ReleaseMemoryInfo(memory);
        if (environment) api->ReleaseEnv(environment);
        if (library) dlclose(library);
    }
    void check(OrtStatus* status) {
        if (!status) return;
        std::string error=api->GetErrorMessage(status);api->ReleaseStatus(status);
        throw std::runtime_error(error);
    }
};
extern "C" int OSWPiiCreate(const char* path,const void* model,size_t bytes,int coreml,
                            OSWPiiSession** output,char* error,size_t capacity) {
    if (output) *output=nullptr;
    try {
        require(output && path && model && bytes>0 && bytes<=200000000,"Invalid native PII model input");
        require(coreml==0 || coreml==1,"Invalid native PII compute policy");
        auto result=std::make_unique<OSWPiiSession>();result->coreml=coreml;
        result->library=dlopen(path,RTLD_NOW | RTLD_LOCAL);
        require(result->library,"Cannot load verified ONNX Runtime library");
        auto get=reinterpret_cast<const OrtApiBase* (*)()>(dlsym(result->library,"OrtGetApiBase"));
        require(get,"Missing native PII runtime API");const auto* base=get();
        require(base && std::strcmp(base->GetVersionString(),"1.24.2")==0,"Unexpected ONNX Runtime version");
        result->api=base->GetApi(24);require(result->api,"Missing pinned ONNX Runtime API");
        auto* api=result->api;
        result->check(api->CreateEnv(ORT_LOGGING_LEVEL_ERROR,"oswind-pii",&result->environment));
        result->check(api->DisableTelemetryEvents(result->environment));
        OrtSessionOptions* raw=nullptr;result->check(api->CreateSessionOptions(&raw));
        auto release=[&](OrtSessionOptions* p){api->ReleaseSessionOptions(p);};
        std::unique_ptr<OrtSessionOptions,decltype(release)> options(raw,release);
        result->check(api->SetIntraOpNumThreads(raw,4));result->check(api->SetInterOpNumThreads(raw,1));
        if (coreml) {
            const char* keys[]={"ModelFormat","MLComputeUnits","RequireStaticInputShapes","EnableOnSubgraphs"};
            const char* values[]={"MLProgram","CPUAndGPU","0","0"};
            result->check(api->SessionOptionsAppendExecutionProvider(raw,"CoreML",keys,values,4));
        }
        // This exact ONNX (not ORT-format) model parses into owned ModelProto
        // storage in pinned1.24.2; direct model-byte/initializer options are unset.
        result->check(api->CreateSessionFromArray(result->environment,model,bytes,raw,&result->session));
        result->check(api->CreateCpuMemoryInfo(OrtArenaAllocator,OrtMemTypeDefault,&result->memory));
        size_t inputs=0,outputs=0;result->check(api->SessionGetInputCount(result->session,&inputs));
        result->check(api->SessionGetOutputCount(result->session,&outputs));
        require(inputs==4 && outputs==1,"Unexpected native PII input/output contract");
        *output=result.release();return 0;
    } catch (const std::exception& exception) {fail(error,capacity,exception.what());return 1;}
      catch (...) {fail(error,capacity,"Native PII model initialization failed");return 1;}
}
extern "C" int OSWPiiRun(OSWPiiSession* state,const int64_t* ids,const int64_t* attention,
                         const int64_t* mask,size_t tokens,int64_t words,float* output,
                         size_t count,char* error,size_t capacity) {
    try {
        require(state && ids && attention && mask && output,"Missing native PII tensors");
        require(tokens>=3 && tokens<=512 && words>0 && words<=512 && size_t(words)<=tokens &&
                count==size_t(words)*12*3,"Invalid native PII tensor dimensions");
        require(!state->coreml || tokens==128,"Core ML PII requires128 padded tokens");
        size_t active=0;int64_t nextWord=1;bool padded=false;
        for (size_t i=0;i<tokens;++i) {
            require(ids[i]>=0 && ids[i]<50370 && (attention[i]==0 || attention[i]==1),"Invalid native PII input values");
            require(mask[i]>=0 && mask[i]<=words,"Invalid native PII word mask");
            if (!attention[i]) {padded=true;require(ids[i]==50283 && mask[i]==0,"Invalid native PII padding");}
            else {require(!padded,"Noncontiguous native PII attention");++active;}
            if (mask[i]) {require(mask[i]==nextWord,"Native PII words are missing/out of order");++nextWord;}
        }
        require(active>=3 && ids[0]==50281 && ids[active-1]==50282 && nextWord==words+1,
                "Incomplete native PII framing/word coverage");
        require(state->coreml || active==tokens,"Unexpected padding in dynamic CPU PII input");
        const auto* api=state->api;
        auto releaseValue=[&](OrtValue* p){api->ReleaseValue(p);};
        std::unique_ptr<OrtValue,decltype(releaseValue)> owned[4]={{nullptr,releaseValue},{nullptr,releaseValue},{nullptr,releaseValue},{nullptr,releaseValue}};
        const int64_t shape[]={1,static_cast<int64_t>(tokens)},lengthShape[]={1,1};
        const int64_t* data[]={ids,attention,mask,&words};const OrtValue* inputs[4]{};
        for (size_t i=0;i<4;++i) {
            OrtValue* raw=nullptr;
            state->check(api->CreateTensorWithDataAsOrtValue(state->memory,const_cast<int64_t*>(data[i]),
                (i==3 ? 1:tokens)*sizeof(int64_t),i==3 ? lengthShape:shape,2,
                ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64,&raw));
            owned[i].reset(raw);inputs[i]=raw;
        }
        const char* names[]={"input_ids","attention_mask","words_mask","text_lengths"};
        const char* outputs[]={"logits"};OrtValue* rawOutput=nullptr;
        auto* runStatus=api->Run(state->session,nullptr,names,inputs,4,outputs,1,&rawOutput);
        std::unique_ptr<OrtValue,decltype(releaseValue)> result(rawOutput,releaseValue);
        state->check(runStatus);
        OrtTensorTypeAndShapeInfo* rawShape=nullptr;auto* shapeStatus=api->GetTensorTypeAndShape(rawOutput,&rawShape);
        auto releaseShape=[&](OrtTensorTypeAndShapeInfo* p){api->ReleaseTensorTypeAndShapeInfo(p);};
        std::unique_ptr<OrtTensorTypeAndShapeInfo,decltype(releaseShape)> resultShape(rawShape,releaseShape);
        state->check(shapeStatus);
        ONNXTensorElementDataType type;state->check(api->GetTensorElementType(rawShape,&type));
        size_t rank=0;state->check(api->GetDimensionsCount(rawShape,&rank));
        require(type==ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT && rank==4,"Invalid native PII output type/rank");
        int64_t dimensions[4]{};state->check(api->GetDimensions(rawShape,dimensions,4));
        require(dimensions[0]==1 && dimensions[1]==words && dimensions[2]==12 && dimensions[3]==3,
                "Invalid native PII output shape");
        void* resultData=nullptr;state->check(api->GetTensorMutableData(rawOutput,&resultData));
        require(resultData,"Missing native PII output data");const auto* values=static_cast<float*>(resultData);
        for (size_t i=0;i<count;++i) require(std::isfinite(values[i]),"Nonfinite native PII result");
        std::copy(values,values+count,output);return 0;
    } catch (const std::exception& exception) {fail(error,capacity,exception.what());return 1;}
      catch (...) {fail(error,capacity,"Native PII inference failed");return 1;}
}
extern "C" void OSWPiiDestroy(OSWPiiSession* state) {delete state;}
