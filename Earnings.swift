import Foundation

struct NOIDAmount:Decodable {
 let formatted:String
 init(from decoder:Decoder) throws {
  let container=try decoder.singleValueContainer(),raw=try container.decode(String.self)
  guard !raw.isEmpty,raw.utf8.allSatisfy({$0>=48 && $0<=57}) else{throw DecodingError.dataCorruptedError(in:container,debugDescription:"Expected unsigned atomic NOID amount")}
  // NOID has 6 decimal places; format the integer string without floating-point rounding.
  let digits=raw.drop(while:{$0=="0"}),padded=String(repeating:"0",count:max(0,7-digits.count))+digits
  let fraction=String(padded.suffix(6).reversed().drop(while:{$0=="0"}).reversed())
  formatted=String(padded.dropLast(6))+(fraction.isEmpty ? "":"."+fraction)
 }
}

struct PoolEarnings:Decodable {
 struct Balance:Decodable {let confirmed:NOIDAmount,pending:NOIDAmount,paid:NOIDAmount}
 struct Immature:Decodable {let amount:NOIDAmount,status:String,financial:Bool,blocks:Int}
 let coin:String,address:String,found:Bool
 let balance:Balance?
 let immatureEstimate:Immature?
 var immatureAmount:String {
  guard let value=immatureEstimate,value.status=="estimated_immature",!value.financial,value.blocks>0 else{return "—"}
  return value.amount.formatted
 }
 static func decode(_ data:Data,address:String) throws -> PoolEarnings {
  let value=try JSONDecoder().decode(Self.self,from:data)
  guard value.coin=="parano1d",value.address==address,!value.found || value.balance != nil else{
   throw DecodingError.dataCorrupted(.init(codingPath:[],debugDescription:"Unexpected earnings account or missing balance"))
  }
  return value
 }
}
