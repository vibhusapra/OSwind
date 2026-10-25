import Foundation
import CoreML
import Darwin

struct Fixture:Decodable {let id:String;let ids:[Int32];let mask:[Int32];let expected:[Int]}
struct Observation:Codable {let id:String;let repetition:Int;let seconds:Double;let activeLabelDifferences:Int}
func residentBytes()->UInt64 {
    var info=mach_task_basic_info();var count=mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<natural_t>.size)
    let result=withUnsafeMutablePointer(to:&info) {pointer in pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count)}}
    return result==KERN_SUCCESS ? info.resident_size:0
}
func footprintBytes()->UInt64 {
    var info=task_vm_info_data_t();var count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<natural_t>.size)
    let result=withUnsafeMutablePointer(to:&info) {pointer in pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)}}
    return result==KERN_SUCCESS ? info.phys_footprint:0
}
let args=CommandLine.arguments
guard args.count==5,let repetitions=Int(args[4]),(1...5).contains(repetitions),["cpu","gpu"].contains(args[3]) else {fatalError("Use owned-model owned-fixtures cpu|gpu repetitions")}
let fixtures=try JSONDecoder().decode([Fixture].self,from:Data(contentsOf:URL(fileURLWithPath:args[2])))
guard fixtures.count==256,fixtures.allSatisfy({$0.ids.count==256 && $0.mask.count==256 && $0.expected.count==256 && $0.ids.allSatisfy {(0..<28996).contains($0)} && $0.mask.allSatisfy {$0==0 || $0==1}}) else {fatalError("Fixture contract differs")}
let beforeResident=residentBytes(),beforeFootprint=footprintBytes(),config=MLModelConfiguration();config.computeUnits=args[3]=="cpu" ? .cpuOnly:.cpuAndGPU
let loadStart=ContinuousClock.now,model=try MLModel(contentsOf:URL(fileURLWithPath:args[1]),configuration:config),loadDuration=loadStart.duration(to:.now)
guard model.modelDescription.inputDescriptionsByName.count==2,let contract=model.modelDescription.outputDescriptionsByName["logits"]?.multiArrayConstraint,contract.shape.map(\.intValue)==[1,256,9],contract.dataType == .float32 else {fatalError("Model contract differs")}
var observations=[Observation](),maximumResident=residentBytes(),maximumFootprint=footprintBytes()
for repetition in 0..<repetitions {for fixture in fixtures {
    try autoreleasepool {
        let ids=try MLMultiArray(shape:[1,256],dataType:.int32),mask=try MLMultiArray(shape:[1,256],dataType:.int32)
        for i in 0..<256 {ids[i]=NSNumber(value:fixture.ids[i]);mask[i]=NSNumber(value:fixture.mask[i])}
        let input=try MLDictionaryFeatureProvider(dictionary:["input_ids":MLFeatureValue(multiArray:ids),"attention_mask":MLFeatureValue(multiArray:mask)]),start=ContinuousClock.now
        let result=try model.prediction(from:input),duration=start.duration(to:.now)
        guard let logits=result.featureValue(for:"logits")?.multiArrayValue,logits.count==256*9 else {fatalError("Invalid model output")}
        var differences=0
        for token in 0..<256 where fixture.mask[token] != 0 {
            var best=0,value = -Float.infinity
            for label in 0..<9 {let logit=logits[[NSNumber(value:0),NSNumber(value:token),NSNumber(value:label)]].floatValue;guard logit.isFinite else {fatalError("Non-finite native output")};if logit>value {best=label;value=logit}}
            if best != fixture.expected[token] {differences+=1}
        }
        observations.append(.init(id:fixture.id,repetition:repetition,seconds:Double(duration.components.seconds)+Double(duration.components.attoseconds)/1e18,activeLabelDifferences:differences))
        maximumResident=max(maximumResident,residentBytes());maximumFootprint=max(maximumFootprint,footprintBytes())
    }
}}
var usage=rusage();getrusage(RUSAGE_SELF,&usage)
let data=try JSONEncoder().encode(observations),rows=try JSONSerialization.jsonObject(with:data)
let report:[String:Any] = ["policy":args[3],"loadSeconds":Double(loadDuration.components.seconds)+Double(loadDuration.components.attoseconds)/1e18,"beforeResidentBytes":beforeResident,"beforePhysicalFootprintBytes":beforeFootprint,"maximumObservedResidentBytes":maximumResident,"maximumObservedPhysicalFootprintBytes":maximumFootprint,"processPeakRSSBytes":usage.ru_maxrss,"actualPerOperationPlacementMeasured":false,"observations":rows,"scope":"New standalone optimized Swift process, pinned public model and validation token tensors. Policy permits GPU; actual placement, power, idle release and app/capture behavior are not established. No Python runtime or normal history in this process."]
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]));FileHandle.standardOutput.write(Data([10]))
