import Foundation

final class EarningsResponse:URLProtocol {
 static let lock=NSLock()
 static var requests:[URLRequest]=[]
 static var status=200,amount="1234567",delay=0.0
 private var work:DispatchWorkItem?
 override class func canInit(with request:URLRequest)->Bool{true}
 override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
 static func configure(status:Int=200,amount:String="1234567",delay:Double=0){lock.lock();self.status=status;self.amount=amount;self.delay=delay;lock.unlock()}
 static var count:Int{lock.lock();defer{lock.unlock()};return requests.count}
 override func startLoading(){
  Self.lock.lock();Self.requests.append(request);let status=Self.status,amount=Self.amount,delay=Self.delay;Self.lock.unlock()
  let address=request.url!.lastPathComponent
  let data=Data("{\"coin\":\"parano1d\",\"address\":\"\(address)\",\"found\":true,\"balance\":{\"confirmed\":\"\(amount)\",\"pending\":\"0\",\"paid\":\"0\"}}".utf8)
  let work=DispatchWorkItem{[weak self] in
   guard let self=self else{return}
   self.client?.urlProtocol(self,didReceive:HTTPURLResponse(url:self.request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
   self.client?.urlProtocol(self,didLoad:data);self.client?.urlProtocolDidFinishLoading(self)
  }
  self.work=work;DispatchQueue.global().asyncAfter(deadline:.now()+delay,execute:work)
 }
 override func stopLoading(){work?.cancel()}
}

@main struct TestEarnings {
 static func wait(_ condition:()->Bool){
  let deadline=Date().addingTimeInterval(3)
  while !condition() && Date()<deadline{RunLoop.main.run(until:Date().addingTimeInterval(0.01))}
  precondition(condition(),"Asynchronous earnings check timed out")
 }
 static func main() throws {
  let decoder=JSONDecoder()
  for (raw,expected) in [("0","0"),("1","0.000001"),("1000000","1"),("1234567","1.234567"),("001230000","1.23"),("9007199254740993","9007199254.740993")] {
   let data=try JSONEncoder().encode(raw)
   let amount=try decoder.decode(NOIDAmount.self,from:data)
   precondition(amount.formatted==expected)
  }
  for invalid in ["\"\"","\"-1\"","\"1.5\"","\"1e6\"","\" 12\"","\"１２\"","123","null"] {
   do{_ = try decoder.decode(NOIDAmount.self,from:Data(invalid.utf8));fatalError("Accepted invalid amount: \(invalid)")}catch{}
  }
  print("Exact NOID units and invalid amount handling passed")
  let data=Data(#"{"coin":"parano1d","address":"test","found":true,"balance":{"confirmed":"1234567","pending":"2000000","paid":"9007199254740993"},"immatureEstimate":{"amount":"50","status":"estimated_immature","financial":false,"blocks":2}}"#.utf8)
  let earnings=try PoolEarnings.decode(data,address:"test")
  precondition(earnings.balance?.confirmed.formatted=="1.234567" && earnings.balance?.pending.formatted=="2")
  precondition(earnings.balance?.paid.formatted=="9007199254.740993" && earnings.immatureAmount=="0.00005")
  for invalid in [data,Data(#"{"coin":"other","address":"test","found":true}"#.utf8),Data(#"{"coin":"parano1d","address":"test","found":true}"#.utf8)] {
   do{_ = try PoolEarnings.decode(invalid,address:invalid==data ? "different":"test");fatalError("Accepted mismatched or incomplete earnings")}catch{}
  }
  let unknown=try PoolEarnings.decode(Data(#"{"coin":"parano1d","address":"test","found":false}"#.utf8),address:"test")
  precondition(!unknown.found && unknown.balance==nil && unknown.immatureAmount=="—")
  let notEstimate=try PoolEarnings.decode(Data(String(decoding:data,as:UTF8.self).replacingOccurrences(of:"\"financial\":false",with:"\"financial\":true").utf8),address:"test")
  precondition(notEstimate.immatureAmount=="—")
  print("Account matching, balance validation and immature estimate handling passed")

  let address="o12p4r8dl49ys3462zrqqys5vz8ll8m93su6lc70wu7rrwg3nn7fgsd7jnnt"
  let other="o17z7pfmh09rjztwga8y9pzpy05ncznl5teqe23a48d0sumjcnrlaszlk2vj"
  precondition(validWallet(address) && validWallet(other))
  let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[EarningsResponse.self]
  let session=URLSession(configuration:config);defer{session.invalidateAndCancel()}
  let model=MiningModel(directory:URL(fileURLWithPath:"/tmp/noid-test-no-miner"),earningsSession:session)
  model.wallet=address;model.refreshEarnings(now:1000);wait{!model.earningsLoading}
  precondition(model.earnings?.balance?.confirmed.formatted=="1.234567" && EarningsResponse.count==1)
  precondition(EarningsResponse.requests.first?.url?.absoluteString=="https://noid.innovlab.cc/api/coins/parano1d/miner/\(address)")
  EarningsResponse.configure(amount:"2000000")
  model.refreshEarnings(now:1030);model.refreshEarnings(now:1299)
  precondition(!model.earningsLoading && EarningsResponse.count==1 && model.earnings?.balance?.confirmed.formatted=="1.234567")
  model.refreshEarnings(now:1300);wait{!model.earningsLoading}
  precondition(EarningsResponse.count==2 && model.earnings?.balance?.confirmed.formatted=="2")
  EarningsResponse.configure(amount:"3000000")
  model.refreshEarnings(force:true,now:1301);wait{!model.earningsLoading}
  precondition(EarningsResponse.count==3 && model.earnings?.balance?.confirmed.formatted=="3")
  let updated=model.earningsUpdated
  EarningsResponse.configure(status:500)
  model.refreshEarnings(force:true,now:1302);wait{!model.earningsLoading}
  precondition(model.earnings?.balance?.confirmed.formatted=="3" && model.earningsUpdated==updated && !model.earningsStatus.isEmpty)
  model.refreshEarnings(now:1601);precondition(!model.earningsLoading && EarningsResponse.count==4)
  EarningsResponse.configure(amount:"4000000")
  model.refreshEarnings(now:1602);wait{!model.earningsLoading}
  precondition(EarningsResponse.count==5 && model.earnings?.balance?.confirmed.formatted=="4")
  EarningsResponse.configure(amount:"5000000",delay:0.2)
  model.refreshEarnings(force:true,now:1603);wait{EarningsResponse.count==6}
  model.wallet=other;model.refreshEarnings(now:1604)
  precondition(model.earnings==nil && model.earningsUpdated==nil)
  model.wallet=address;model.refreshEarnings(now:1605)
  RunLoop.main.run(until:Date().addingTimeInterval(0.05))
  precondition(model.earningsLoading && model.earnings==nil)
  wait{!model.earningsLoading}
  precondition(model.earnings?.address==address && model.earnings?.balance?.confirmed.formatted=="5")
  model.wallet="invalid";model.refreshEarnings(now:1606)
  precondition(model.earnings==nil && model.earningsUpdated==nil && !model.earningsLoading)
  print("Five-minute polling, manual refresh, error retention and wallet-switch cancellation passed")
 }
}
