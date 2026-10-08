import Foundation
import IOKit

final class TemperatureSensors {
 private struct Sensor {
  let key:UInt32,size:UInt32,type:UInt32
 }
 private var connection:io_connect_t=0
 private var cpu:[Sensor]=[],gpu:[Sensor]=[]

 // Sensor keys: https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift
 // ponytail: only known Apple Silicon keys are probed; extend these lists when new chips change the mapping.
 private static let cpuKeys="Te05 Te06 Te09 Te0H Te0L Te0P Te0S Te0T Tp00 Tp01 Tp04 Tp05 Tp08 Tp09 Tp0C Tp0D Tp0G Tp0H Tp0K Tp0L Tp0O Tp0P Tp0R Tp0T Tp0U Tp0V Tp0X Tp0Y Tp0a Tp0b Tp0d Tp0e Tp0f Tp0g Tp0j Tp0m Tp0p Tp0u Tp0y Tp1h Tp1l Tp1p Tp1t Tf04 Tf09 Tf0A Tf0B Tf0D Tf0E Tf44 Tf49 Tf4A Tf4B Tf4D Tf4E"
 private static let gpuKeys="Tg05 Tg0D Tg0G Tg0H Tg0K Tg0L Tg0T Tg0U Tg0X Tg0d Tg0e Tg0f Tg0g Tg0j Tg0k Tg1U Tg1Y Tg1c Tg1g Tg1k Tf14 Tf18 Tf19 Tf1A Tf24 Tf28 Tf29 Tf2A"

 deinit {if connection != 0{IOServiceClose(connection)}}

 func read()->(cpu:Double?,gpu:Double?) {
  if connection==0 {
   let service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC"))
   guard service != 0 else{return(nil,nil)}
   let result=IOServiceOpen(service,mach_task_self_,0,&connection)
   IOObjectRelease(service)
   guard result==KERN_SUCCESS,connection != 0 else{connection=0;return(nil,nil)}
   cpu=discover(Self.cpuKeys);gpu=discover(Self.gpuKeys)
  }
  let cpuTemperature=cpu.compactMap{read($0)}.max()
  let gpuTemperature=gpu.compactMap{read($0)}.max()
  // Reopen after a failed connection (for example after sleep); never keep an old temperature.
  if cpuTemperature==nil && gpuTemperature==nil {IOServiceClose(connection);connection=0;cpu=[];gpu=[]}
  return(cpuTemperature,gpuTemperature)
 }

 private func discover(_ keys:String)->[Sensor] {
  keys.split(separator:" ").compactMap{key in
   let code=key.utf8.reduce(UInt32(0)){($0<<8) | UInt32($1)}
   guard let info=call(command:9,key:code) else{return nil}
   let size=Self.word(info,at:28),type=Self.word(info,at:32)
   guard (type==0x666c7420 && size==4) || (type==0x73703738 && size==2) else{return nil}
   return Sensor(key:code,size:size,type:type)
  }
 }

 private func read(_ sensor:Sensor)->Double? {
  guard let reply=call(command:5,key:sensor.key,size:sensor.size) else{return nil}
  return Self.decode(Array(reply[48..<48+Int(sensor.size)]),type:sensor.type)
 }

 private func call(command:UInt8,key:UInt32,size:UInt32=0)->[UInt8]? {
  // AppleSMC's 80-byte ABI: key@0, size@28, type@32, result@40, command@42, payload@48.
  // Protocol reference: https://github.com/vladkens/macmon/blob/main/src/sources.rs
  var input=[UInt8](repeating:0,count:80),output=[UInt8](repeating:0,count:80)
  withUnsafeBytes(of:key.littleEndian){input.replaceSubrange(0..<4,with:$0)}
  withUnsafeBytes(of:size.littleEndian){input.replaceSubrange(28..<32,with:$0)}
  input[42]=command
  var outputSize=output.count
  let result=input.withUnsafeBytes{request in
   output.withUnsafeMutableBytes{response in
    IOConnectCallStructMethod(connection,2,request.baseAddress,request.count,response.baseAddress,&outputSize)
   }
  }
  guard result==KERN_SUCCESS,outputSize==80,output[40]==0 else{return nil}
  return output
 }

 private static func word(_ bytes:[UInt8],at offset:Int)->UInt32 {
  bytes.withUnsafeBytes{UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:offset,as:UInt32.self))}
 }

 static func decode(_ bytes:[UInt8],type:UInt32)->Double? {
  let value:Double
  switch type {
  case 0x666c7420: // flt : little-endian IEEE 754.
   guard bytes.count==4 else{return nil}
   value=Double(Float(bitPattern:word(bytes,at:0)))
  case 0x73703738: // sp78: big-endian signed fixed point with 8 fractional bits.
   guard bytes.count==2 else{return nil}
   value=Double(Int16(bitPattern:UInt16(bytes[0])<<8 | UInt16(bytes[1])))/256
  default:return nil
  }
  return value.isFinite && value>0 && value<=150 ? value:nil
 }
}
