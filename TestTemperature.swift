import Foundation

@main struct TestTemperature {
 static func main() {
  // Hand-encoded 42.5 °C: little-endian IEEE 754 and big-endian signed 8.8.
  precondition(TemperatureSensors.decode([0x00,0x00,0x2a,0x42],type:0x666c7420)==42.5)
  precondition(TemperatureSensors.decode([0x2a,0x80],type:0x73703738)==42.5)
  precondition(TemperatureSensors.decode([0x00,0x00,0xdc,0x42],type:0x666c7420)==110)
  for bytes:[UInt8] in [[],[0,0,0],[0,0,0,0,0],[0,0,0,0],[0,0,0x80,0xbf],[0,0,0x80,0x7f],[0,0,0xc0,0x7f],[0,0,0x17,0x43]] {
   precondition(TemperatureSensors.decode(bytes,type:0x666c7420)==nil)
  }
  precondition(TemperatureSensors.decode([0xff,0x80],type:0x73703738)==nil)
  precondition(TemperatureSensors.decode([0x2a],type:0x73703738)==nil)
  precondition(TemperatureSensors.decode([0x2a,0x80,0],type:0x73703738)==nil)
  precondition(TemperatureSensors.decode([0,0,0x2a,0x42],type:0x75693332)==nil)
  print("Temperature decoding, invalid values and missing readings passed")
  if CommandLine.arguments.contains("--live") {
   let sensors=TemperatureSensors()
   for _ in 0..<3 {
    let reading=sensors.read()
    guard let cpu=reading.cpu,let gpu=reading.gpu else{fatalError("CPU or GPU temperature is unavailable on this Mac")}
    print(String(format:"CPU max: %.1f °C, GPU max: %.1f °C",cpu,gpu))
    Thread.sleep(forTimeInterval:2)
   }
  }
 }
}
