// Standalone macOS experiment, not linked into OSwind. No tokenizer or decoder.
// Header/runtime: ONNX Runtime 1.24.2. Accept only the bounded authored fixture
// binary produced by export-native-fixtures.py. Never feed normal history.
#include "onnxruntime_c_api.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <dlfcn.h>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <sys/resource.h>
#include <vector>

using Clock = std::chrono::steady_clock;
static double seconds(Clock::time_point start) {
    return std::chrono::duration<double>(Clock::now() - start).count();
}
static void require(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}
template<class T> static T read(std::istream& stream) {
    T value{}; stream.read(reinterpret_cast<char*>(&value), sizeof(value));
    require(bool(stream), "Truncated tensor fixture"); return value;
}
struct Tensor {
    std::vector<int64_t> shape;
    std::vector<int64_t> integers;
    std::vector<float> floats;
};
static Tensor tensor(std::istream& stream, bool floating) {
    Tensor result; auto rank = read<uint32_t>(stream);
    require(rank >= 1 && rank <= 4, "Invalid tensor rank");
    uint64_t count = 1;
    for (unsigned i = 0; i < rank; ++i) {
        auto dim = read<uint64_t>(stream);
        require(dim > 0 && dim <= 1'000'000 && count <= 1'000'000 / dim, "Oversized tensor");
        count *= dim; result.shape.push_back(static_cast<int64_t>(dim));
    }
    require(read<uint64_t>(stream) == count, "Invalid tensor element count");
    if (floating) {
        result.floats.resize(count);
        stream.read(reinterpret_cast<char*>(result.floats.data()), count * sizeof(float));
        for (float value : result.floats) require(std::isfinite(value), "Nonfinite reference");
    } else {
        result.integers.resize(count);
        stream.read(reinterpret_cast<char*>(result.integers.data()), count * sizeof(int64_t));
    }
    require(bool(stream), "Truncated tensor data"); return result;
}
struct Case { std::vector<Tensor> inputs; Tensor expected; };
int main(int argc, char** argv) {
    try {
        require(argc == 7, "usage: native-probe DYLIB MODEL FIXTURES cpu|coreml PROFILE_PREFIX REPETITIONS");
        const std::string policy = argv[4];
        require(policy == "cpu" || policy == "coreml", "Invalid compute policy");
        const std::string repetitionsText = argv[6];
        require(!repetitionsText.empty() && repetitionsText.size() <= 3 &&
                repetitionsText.find_first_not_of("0123456789") == std::string::npos, "Invalid repetitions");
        const unsigned repetitions = std::stoul(repetitionsText);
        require(repetitions >= 2 && repetitions <= 100, "Invalid repetitions");
        std::ifstream stream(argv[3], std::ios::binary);
        char magic[8]{}; stream.read(magic, 8);
        require(std::memcmp(magic, "OSWPII01", 8) == 0, "Invalid tensor fixture format");
        const auto count = read<uint32_t>(stream);
        require(count == 3, "Expected three fixed validation cases");
        std::vector<Case> cases;
        for (unsigned i = 0; i < count; ++i) {
            Case value;
            for (unsigned j = 0; j < 4; ++j) value.inputs.push_back(tensor(stream, false));
            value.expected = tensor(stream, true);
            require(value.expected.shape.size() == 4 && value.expected.shape.back() == 3, "Invalid logit layout");
            require(value.inputs[0].shape.size() == 2 && value.inputs[0].shape[0] == 1 &&
                    value.inputs[0].shape[1] <= 512, "Invalid input bound");
            require(value.inputs[1].shape == value.inputs[0].shape && value.inputs[2].shape == value.inputs[0].shape &&
                    value.inputs[3].shape == std::vector<int64_t>({1, 1}), "Input dimensions differ");
            cases.push_back(std::move(value));
        }
        require(stream.peek() == std::char_traits<char>::eof(), "Unexpected fixture bytes");
        void* library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        require(library, "Cannot load explicit ONNX Runtime dylib");
        auto getBase = reinterpret_cast<const OrtApiBase* (*)()>(dlsym(library, "OrtGetApiBase"));
        require(getBase, "Missing ONNX Runtime API");
        const auto* base = getBase();
        require(std::string(base->GetVersionString()) == "1.24.2", "Unexpected ONNX Runtime version");
        const OrtApi* api = base->GetApi(ORT_API_VERSION);
        require(api, "Missing ONNX Runtime API version");
        auto check = [&](OrtStatus* status) {
            if (!status) return;
            std::string message = api->GetErrorMessage(status); api->ReleaseStatus(status);
            throw std::runtime_error(message);
        };
        // Destruction order keeps the API library resident through all releases.
        auto releaseEnv = [&](OrtEnv* p) { api->ReleaseEnv(p); };
        auto releaseOptions = [&](OrtSessionOptions* p) { api->ReleaseSessionOptions(p); };
        auto releaseSession = [&](OrtSession* p) { api->ReleaseSession(p); };
        auto releaseMemory = [&](OrtMemoryInfo* p) { api->ReleaseMemoryInfo(p); };
        auto releaseValue = [&](OrtValue* p) { api->ReleaseValue(p); };
        auto releaseShape = [&](OrtTensorTypeAndShapeInfo* p) { api->ReleaseTensorTypeAndShapeInfo(p); };
        OrtEnv* envRaw = nullptr; check(api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "oswind-pii-probe", &envRaw));
        std::unique_ptr<OrtEnv, decltype(releaseEnv)> env(envRaw, releaseEnv);
        OrtSessionOptions* optionsRaw = nullptr; check(api->CreateSessionOptions(&optionsRaw));
        std::unique_ptr<OrtSessionOptions, decltype(releaseOptions)> options(optionsRaw, releaseOptions);
        check(api->SetIntraOpNumThreads(options.get(), 4)); check(api->SetInterOpNumThreads(options.get(), 1));
        check(api->EnableProfiling(options.get(), argv[5]));
        if (policy == "coreml") {
            const char* keys[] = {"ModelFormat", "MLComputeUnits", "RequireStaticInputShapes", "EnableOnSubgraphs"};
            const char* values[] = {"MLProgram", "CPUAndGPU", "0", "0"};
            check(api->SessionOptionsAppendExecutionProvider(options.get(), "CoreML", keys, values, 4));
        }
        // CPU is the default provider; no automatic retry or Azure provider.
        auto loadStart = Clock::now();
        OrtSession* sessionRaw = nullptr; check(api->CreateSession(env.get(), argv[2], options.get(), &sessionRaw));
        std::unique_ptr<OrtSession, decltype(releaseSession)> session(sessionRaw, releaseSession);
        const double loadSeconds = seconds(loadStart);
        OrtMemoryInfo* memoryRaw = nullptr; check(api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memoryRaw));
        std::unique_ptr<OrtMemoryInfo, decltype(releaseMemory)> memory(memoryRaw, releaseMemory);
        const char* names[] = {"input_ids", "attention_mask", "words_mask", "text_lengths"};
        const char* outputNames[] = {"logits"};
        double maximumDifference = 0, first = 0;
        std::vector<double> warm;
        std::vector<double> allTimes;
        for (unsigned repeat = 0; repeat < repetitions; ++repeat) {
            for (auto& item : cases) {
                std::vector<std::unique_ptr<OrtValue, decltype(releaseValue)>> owned;
                const OrtValue* inputs[4]{};
                for (unsigned i = 0; i < 4; ++i) {
                    auto& input = item.inputs[i]; OrtValue* raw = nullptr;
                    check(api->CreateTensorWithDataAsOrtValue(memory.get(), input.integers.data(),
                        input.integers.size() * sizeof(int64_t), input.shape.data(), input.shape.size(),
                        ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &raw));
                    owned.emplace_back(raw, releaseValue); inputs[i] = raw;
                }
                auto start = Clock::now(); OrtValue* outputRaw = nullptr;
                check(api->Run(session.get(), nullptr, names, inputs, 4, outputNames, 1, &outputRaw));
                const auto elapsed = seconds(start);
                allTimes.push_back(elapsed);
                std::unique_ptr<OrtValue, decltype(releaseValue)> output(outputRaw, releaseValue);
                if (repeat == 0 && &item == &cases[0]) first = elapsed;
                if (repeat > 0) warm.push_back(elapsed); // Full first shape sweep excluded; all samples retained below.
                OrtTensorTypeAndShapeInfo* shapeRaw = nullptr; check(api->GetTensorTypeAndShape(output.get(), &shapeRaw));
                std::unique_ptr<OrtTensorTypeAndShapeInfo, decltype(releaseShape)> shape(shapeRaw, releaseShape);
                ONNXTensorElementDataType type; check(api->GetTensorElementType(shape.get(), &type));
                require(type == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, "Unexpected output type");
                size_t rank = 0; check(api->GetDimensionsCount(shape.get(), &rank));
                require(rank == item.expected.shape.size(), "Output rank differs");
                std::vector<int64_t> dimensions(rank); check(api->GetDimensions(shape.get(), dimensions.data(), rank));
                require(dimensions == item.expected.shape, "Output dimensions differ");
                void* raw = nullptr; check(api->GetTensorMutableData(output.get(), &raw));
                const auto* values = static_cast<float*>(raw);
                for (size_t i = 0; i < item.expected.floats.size(); ++i) {
                    require(std::isfinite(values[i]), "Nonfinite native output");
                    maximumDifference = std::max(maximumDifference, std::abs(double(values[i]) - item.expected.floats[i]));
                }
                require(maximumDifference <= 0.001, "Native logits exceed frozen tolerance");
            }
        }
        OrtAllocator* allocator = nullptr; check(api->GetAllocatorWithDefaultOptions(&allocator));
        char* profileRaw = nullptr; check(api->SessionEndProfiling(session.get(), allocator, &profileRaw));
        // The caller supplies a simple profile prefix. Keep paths out of JSON;
        // detailed assignment evidence is retained by the external wrapper.
        check(api->AllocatorFree(allocator, profileRaw));
        std::sort(warm.begin(), warm.end());
        rusage usage{}; require(getrusage(RUSAGE_SELF, &usage) == 0, "Cannot read resource usage");
        std::cout << "{\"state\":\"completed\",\"runtime\":\"onnxruntime-1.24.2-native\",\"policy\":\"" << policy
                  << "\",\"fixedInputs\":3,\"runs\":" << repetitions * 3 << ",\"loadSeconds\":" << loadSeconds
                  << ",\"firstForwardSeconds\":" << first << ",\"warmForwardMedianSeconds\":" << warm[warm.size()/2]
                  << ",\"warmForwardP95Seconds\":" << warm[std::min(warm.size()-1, size_t(warm.size()*0.95))]
                  << ",\"maxAbsoluteLogitDifference\":" << maximumDifference
                  << ",\"peakRSSBytes\":" << usage.ru_maxrss << ",\"forwardSecondsInRunOrder\":[";
        for (size_t i = 0; i < allTimes.size(); ++i) std::cout << (i ? "," : "") << allTimes[i];
        std::cout << "]}\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n'; return 1;
    }
}
