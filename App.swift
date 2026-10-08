import SwiftUI
import AppKit

enum MiningMode:String,CaseIterable,Identifiable {
 case cpu="CPU",gpu="GPU",both="CPU + GPU"
 var id:String {rawValue}
}
final class WorkerLoad {
 private let lock=NSLock()
 private var percent=70,protect=true
 func set(_ value:Int,_ enabled:Bool){lock.lock();percent=min(100,max(10,value));protect=enabled;lock.unlock()}
 func get()->(Int,Bool){lock.lock();defer{lock.unlock()};return(percent,protect)}
}
final class MiningModel:ObservableObject {
 @Published var wallet=UserDefaults.standard.string(forKey:"wallet") ?? ""
 @Published var mode:MiningMode = .gpu
 @Published var running=false
 @Published var cpuRate=0.0
 @Published var gpuRate=0.0
 @Published var accepted=0
 @Published var rejected=0
 @Published var stale=0
 @Published var logs:[String]=[]
 @Published var cpuThreads=max(1,min(ProcessInfo.processInfo.activeProcessorCount,UserDefaults.standard.object(forKey:"cpuThreads") as? Int ?? 4))
 @Published var gpuIntensity=Double(min(100,max(10,UserDefaults.standard.object(forKey:"gpuIntensity") as? Int ?? 70)))
 @Published var thermalProtection=UserDefaults.standard.object(forKey:"thermalProtection") as? Bool ?? true
 @Published var stopReason=""
 @Published var thermalState=LoadPolicy.thermalLabel(ProcessInfo.processInfo.thermalState)
 @Published var temperatures:(cpu:Double?,gpu:Double?)=(nil,nil)
 @Published var earnings:PoolEarnings?
 @Published var earningsUpdated:Date?
 @Published var earningsLoading=false
 @Published var earningsStatus="输入有效钱包查看收益"
 @Published var endedBackends=0
 private let earningsSession:URLSession
 private var earningsTask:URLSessionDataTask?
 private var earningsAddress="",earningsRequestID=UUID()
 private var lastEarningsAttempt:TimeInterval?
 private let sensorQueue=DispatchQueue(label:"noid.temperature",qos:.utility)
 private lazy var sensors=TemperatureSensors()
 private var readingTemperatures=false
 let load=WorkerLoad()
 let maxThreads=ProcessInfo.processInfo.activeProcessorCount
 var workers:[MiningWorker]=[]
 var remaining=0
 let directory:URL
 init(directory:URL,earningsSession:URLSession = .shared){self.directory=directory;self.earningsSession=earningsSession}
 deinit{earningsTask?.cancel()}
 func refreshEarnings(force:Bool=false,now:TimeInterval=ProcessInfo.processInfo.systemUptime){
  let address=wallet.trimmingCharacters(in:.whitespacesAndNewlines)
  if address != earningsAddress {
   earningsRequestID=UUID();earningsTask?.cancel();earningsTask=nil;earningsAddress=address
   earnings=nil;earningsUpdated=nil;earningsLoading=false;lastEarningsAttempt=nil
  }
  guard validWallet(address) else{earningsStatus="输入有效钱包查看收益";return}
  guard !earningsLoading,force || lastEarningsAttempt.map({now-$0>=300}) ?? true else{return}
  lastEarningsAttempt=now;earningsLoading=true;earningsStatus="查询中…"
  let requestID=UUID();earningsRequestID=requestID
  // ponytail: this is the pool website's API; update the decoder if its schema changes.
  var request=URLRequest(url:URL(string:"https://noid.innovlab.cc/api/coins/parano1d/miner/\(address)")!)
  request.timeoutInterval=15;request.cachePolicy = .reloadIgnoringLocalCacheData
  earningsTask=earningsSession.dataTask(with:request){[weak self] data,response,error in
   let result=Result<PoolEarnings,Error>{
    if let error=error{throw error}
    guard let response=response as? HTTPURLResponse,(200..<300).contains(response.statusCode),let data=data else{throw URLError(.badServerResponse)}
    return try PoolEarnings.decode(data,address:address)
   }
   DispatchQueue.main.async{[weak self] in
    guard let self=self,self.earningsRequestID==requestID,self.wallet.trimmingCharacters(in:.whitespacesAndNewlines)==address else{return}
    self.earningsTask=nil;self.earningsLoading=false
    switch result {
    case .success(let value):self.earnings=value.found ? value:nil;self.earningsUpdated=Date();self.earningsStatus=value.found ? "":"矿池尚无此钱包记录"
    case .failure:self.earningsStatus=self.earnings==nil ? "收益查询失败，可手动重试":"刷新失败，显示上次成功查询的收益"
    }
   }
  }
  earningsTask?.resume()
 }
 func updateLoad(){load.set(Int(gpuIntensity),thermalProtection);UserDefaults.standard.set(cpuThreads,forKey:"cpuThreads");UserDefaults.standard.set(Int(gpuIntensity),forKey:"gpuIntensity");UserDefaults.standard.set(thermalProtection,forKey:"thermalProtection")}
 func updateSensors(){
  thermalState=LoadPolicy.thermalLabel(ProcessInfo.processInfo.thermalState)
  guard !readingTemperatures else{return}
  readingTemperatures=true
  sensorQueue.async{[weak self] in
   guard let self=self else{return}
   let reading=self.sensors.read()
   DispatchQueue.main.async{[weak self] in self?.temperatures=reading;self?.readingTemperatures=false}
  }
 }
 func exportLogs(){
  let panel=NSSavePanel();panel.nameFieldStringValue="NOID-Miner-log.txt"
  guard panel.runModal() == .OK,let url=panel.url else{return}
  let safe=logs.map{$0.replacingOccurrences(of:"o1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{12,88}",with:"[钱包已隐藏]",options:.regularExpression)}
  let text="NOID Miner 0.4.0\nCPU threads: \(cpuThreads), GPU duty target: \(Int(gpuIntensity))%, thermal protection: \(thermalProtection)\n"+safe.joined(separator:"\n")+"\n"
  do{try text.write(to:url,atomically:true,encoding:.utf8)}catch{log("日志保存失败：\(error.localizedDescription)")}
 }
 func log(_ message:String){DispatchQueue.main.async{[weak self] in guard let self=self else{return};self.logs.append(Date().formatted(date:.omitted,time:.standard)+"  "+message);if self.logs.count>150 {self.logs.removeFirst(self.logs.count-150)}}}
 func start(){
  let address=wallet.trimmingCharacters(in:.whitespacesAndNewlines)
  guard !running else{return}
  guard validWallet(address) else{log("请输入有效的 NOID 钱包地址（o1 开头，校验码须正确）");return}
  wallet=address;UserDefaults.standard.set(address,forKey:"wallet")
  updateLoad();running=true;accepted=0;rejected=0;stale=0;cpuRate=0;gpuRate=0;workers=[];stopReason="";endedBackends=0
  let backends = mode == .both ? [false,true]:[mode == .gpu]
  remaining=backends.count
  let suffix=String(UUID().uuidString.prefix(8)).lowercased()
  for gpu in backends {
   let label=gpu ? "GPU":"CPU"
   let w=MiningWorker(gpu:gpu,directory:directory,cpuThreads:cpuThreads,load:{[load] in load.get()},event:{[weak self] message in self?.log(label+" · "+message);if message.hasPrefix("已停止："){DispatchQueue.main.async{self?.stopReason=label+" · "+message}}},rate:{[weak self] rate in DispatchQueue.main.async{if gpu{self?.gpuRate=rate}else{self?.cpuRate=rate}}},share:{[weak self] ok,old in DispatchQueue.main.async{guard let self=self else{return};if ok{self.accepted+=1;self.log(label+" · 矿池已接受份额")}else if old{self.stale+=1}else{self.rejected+=1}}},done:{[weak self] in DispatchQueue.main.async{guard let self=self else{return};self.remaining-=1;self.endedBackends+=1;self.log(label+" · 计算进程已结束");if self.remaining<=0{self.running=false;self.workers=[];self.log("全部矿工已停止")}}})
   workers.append(w);w.start(wallet:address,worker:"mac-\(suffix)-\(gpu ? "gpu":"cpu")")
  }
  log("开始 \(mode.rawValue) · InnovLab / PPLNS · 收款地址 \(address)")
 }
 func stop(){guard running else{return};log("正在停止…");workers.forEach{$0.stop()}}
 func rate(_ value:Double)->String {if value>=1_000_000{return String(format:"%.2f MH/s",value/1_000_000)};if value>=1000{return String(format:"%.1f KH/s",value/1000)};return String(format:"%.0f H/s",value)}
}
struct ContentView:View {
 @ObservedObject var model:MiningModel
 var body:some View {
  VStack(alignment:.leading,spacing:12){
   HStack{VStack(alignment:.leading){Text("NOID Miner").font(.largeTitle.bold());Text("Apple Silicon · InnovLab 矿池").foregroundStyle(.secondary)};Spacer();Text(model.running ? (model.endedBackends>0 ? "部分运行":"运行中"):"已停止").foregroundStyle(model.running ? .green:.secondary)}
   Text("收款钱包").font(.headline)
   TextField("输入你的 NOID 钱包地址（o1…）",text:$model.wallet).textFieldStyle(.roundedBorder).disabled(model.running)
   Picker("计算设备",selection:$model.mode){ForEach(MiningMode.allCases){Text($0.rawValue).tag($0)}}.pickerStyle(.segmented).disabled(model.running)
   HStack(spacing:24){
    Stepper("CPU 线程：\(model.cpuThreads) / \(model.maxThreads)",value:$model.cpuThreads,in:1...model.maxThreads).disabled(model.running || model.mode == .gpu)
    Text("CPU 线程需停止后调整").font(.caption).foregroundStyle(.secondary)
   }
   HStack{Text("GPU 强度：\(Int(model.gpuIntensity))%").frame(width:135,alignment:.leading);Slider(value:$model.gpuIntensity,in:10...100,step:5).disabled(model.mode == .cpu);Text("10–100%").font(.caption).foregroundStyle(.secondary)}
   HStack{Toggle("系统过热自动降载",isOn:$model.thermalProtection);Spacer();Text("散热：\(model.thermalState)").font(.caption).foregroundStyle(.secondary)}
   Text("GPU 强度为目标计算占空比，可运行中调整；不是功耗上限，实际占用率会波动。").font(.caption).foregroundStyle(.secondary)
   HStack{Button("开始挖矿"){model.start()}.buttonStyle(.borderedProminent).disabled(model.running);Button("停止挖矿"){model.stop()}.disabled(!model.running);Spacer();Text("退出程序会停止挖矿").foregroundStyle(.secondary).font(.caption)}
   Divider()
   HStack(spacing:30){metric("CPU 温度（最高）",model.temperatures.cpu.map{String(format:"%.1f °C",$0)} ?? "不可用");metric("GPU 温度（最高）",model.temperatures.gpu.map{String(format:"%.1f °C",$0)} ?? "不可用")}
   HStack(spacing:30){metric("CPU 算力",model.rate(model.cpuRate));metric("GPU 算力",model.rate(model.gpuRate));metric("合计算力",model.rate(model.cpuRate+model.gpuRate))}
   HStack(spacing:30){metric("接受份额",String(model.accepted));metric("拒绝份额",String(model.rejected));metric("过期份额",String(model.stale))}
   earningsSection
   if !model.stopReason.isEmpty{Text(model.stopReason).font(.caption).foregroundStyle(.red).textSelection(.enabled)}
   ScrollViewReader{proxy in ScrollView{LazyVStack(alignment:.leading,spacing:5){ForEach(Array(model.logs.enumerated()),id:\.offset){i,line in Text(line).font(.system(size:11,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).id(i)}}.padding(10)}.background(Color.black.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius:8)).onChange(of:model.logs.count){_ in if let last=model.logs.indices.last {proxy.scrollTo(last,anchor:.bottom)}}}
   HStack{Text("实验版 0.4 · 无私钥输入 · 不随开机自动启动").font(.caption2).foregroundStyle(.secondary);Spacer();Button("导出诊断日志"){model.exportLogs()}.font(.caption)}
  }.padding(24).frame(minWidth:780,minHeight:730)
   .onChange(of:model.gpuIntensity){_ in model.updateLoad()}
   .onChange(of:model.thermalProtection){_ in model.updateLoad()}
   .onAppear{model.updateSensors();model.refreshEarnings()}
   .onChange(of:model.wallet){_ in model.refreshEarnings()}
   .onReceive(Timer.publish(every:2,on:.main,in:.common).autoconnect()){_ in model.updateSensors();model.refreshEarnings()}
 }
 var earningsSection:some View {
  VStack(alignment:.leading,spacing:8){
   HStack{Text("矿池收益 · NOID").font(.headline);Text("每 5 分钟刷新").font(.caption).foregroundStyle(.secondary);Spacer();Button(model.earningsLoading ? "查询中…":"刷新收益"){model.refreshEarnings(force:true)}.disabled(model.earningsLoading || !validWallet(model.wallet.trimmingCharacters(in:.whitespacesAndNewlines)));Link("查看收益",destination:URL(string:"https://noid.innovlab.cc/#miners")!).buttonStyle(.bordered)}
   HStack(spacing:18){metric("可支付",model.earnings?.balance?.confirmed.formatted ?? "—");metric("发款中",model.earnings?.balance?.pending.formatted ?? "—");metric("累计已支付",model.earnings?.balance?.paid.formatted ?? "—");metric("待成熟预估",model.earnings?.immatureAmount ?? "—")}
   HStack{Text(model.earningsStatus);Spacer();if let updated=model.earningsUpdated{Text("查询于 \(updated.formatted(date:.omitted,time:.standard))")}}.font(.caption).foregroundStyle(.secondary)
   Text("钱包合计收益；按 PPLNS 结算，待成熟预估可能变化。").font(.caption).foregroundStyle(.secondary)
  }
 }
 func metric(_ title:String,_ value:String)->some View {VStack(alignment:.leading,spacing:5){Text(title).font(.caption).foregroundStyle(.secondary);Text(value).font(.title3.monospacedDigit().bold())}.frame(maxWidth:.infinity,alignment:.leading)}
}
final class AppDelegate:NSObject,NSApplicationDelegate {
 var model:MiningModel?
 var didResume=false
 func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{true}
 func applicationWillTerminate(_ notification:Notification){model?.stop()}
}
#if !PREVIEW
@main struct NOIDApp:App {
 @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
 @StateObject var model:MiningModel
 init(){
  let directory=Bundle.main.resourceURL!.appendingPathComponent("miner")
  _model=StateObject(wrappedValue:MiningModel(directory:directory))
 }
 var body:some Scene{WindowGroup{ContentView(model:model).onAppear{
  delegate.model=model
  if !delegate.didResume && CommandLine.arguments.contains("--resume-both") {
   delegate.didResume=true;model.mode = .both;model.start()
  }
 }}.windowStyle(.titleBar)}
}
#endif
