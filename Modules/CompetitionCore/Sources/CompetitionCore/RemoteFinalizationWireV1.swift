import Foundation

public struct RemoteFinalizationDayV1: Equatable, Sendable {
    public enum Status:String,Sendable { case points, unavailable }
    public enum Source:String,Sendable { case acceptedRevision="accepted_revision", deadlineMissing="deadline_missing" }
    public let ordinal:Int; public let status:Status; public let source:Source; public let points:Int?; public let reason:String?
    public let wireContentSHA256:String?; public let clientRevision:Int64?; public let serverSequence:Int64?
    public init(ordinal:Int,status:Status,source:Source,points:Int?,reason:String?,wireContentSHA256:String?,clientRevision:Int64?,serverSequence:Int64?) throws {
        guard (1...7).contains(ordinal) else { throw RemoteFinalizationWireV1.ValidationError.invalidWindow }
        let digestOK = wireContentSHA256.map { $0.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil } ?? false
        switch (source,status) {
        case (.deadlineMissing,.unavailable): guard points == nil,reason=="missing",wireContentSHA256==nil,clientRevision==nil,serverSequence==nil else { throw RemoteFinalizationWireV1.ValidationError.invalidWindow }
        case (.acceptedRevision,.points): guard let points,(0...60000).contains(points),reason==nil,digestOK,(clientRevision ?? 0)>0,(serverSequence ?? 0)>0 else { throw RemoteFinalizationWireV1.ValidationError.invalidWindow }
        case (.acceptedRevision,.unavailable): guard points==nil,reason.map(Self.unavailableReasons.contains)==true,digestOK,(clientRevision ?? 0)>0,(serverSequence ?? 0)>0 else { throw RemoteFinalizationWireV1.ValidationError.invalidWindow }
        default: throw RemoteFinalizationWireV1.ValidationError.invalidWindow
        }
        self.ordinal=ordinal;self.status=status;self.source=source;self.points=points;self.reason=reason;self.wireContentSHA256=wireContentSHA256;self.clientRevision=clientRevision;self.serverSequence=serverSequence
    }
    private static let unavailableReasons:Set<String>=["sourceDataUnavailable","unsupportedActivityConfiguration","invalidSourceData","missingMoveValue","missingMoveGoal","nonPositiveMoveGoal","missingExerciseValue","missingExerciseGoal","nonPositiveExerciseGoal","missingStandOrRollValue","missingStandOrRollGoal","nonPositiveStandOrRollGoal","summaryPaused","summaryPauseStateUnknown","invalidNumericCalculation"]
}

public enum RemoteFinalizationWireV1 {
    public enum ValidationError:Error,Equatable,Sendable { case invalidWindow, invalidResult }
    public static func windowCommitment(competitionID:UUID,participantID:UUID,days:[RemoteFinalizationDayV1]) throws->String {
        guard days.count==7,days.map(\.ordinal)==Array(1...7) else { throw ValidationError.invalidWindow }
        var data=Data("healthcomp-owner-window-v1\0".utf8);tlv(&data,1,RemoteScoreRevisionWireV1.uuidBytes(competitionID));tlv(&data,2,RemoteScoreRevisionWireV1.uuidBytes(participantID));tlv(&data,3,Data(RemoteScoringWireV1.policyIdentity.utf8))
        for day in days { var nested=Data("healthcomp-window-day-v1\0".utf8);tlv(&nested,1,RemoteScoreRevisionWireV1.int32Bytes(day.ordinal));tlv(&nested,2,Data(day.status.rawValue.utf8));tlv(&nested,3,day.points.map(RemoteScoreRevisionWireV1.int32Bytes));tlv(&nested,4,day.reason.map{Data($0.utf8)});tlv(&nested,5,try digest(day.wireContentSHA256));tlv(&nested,6,day.clientRevision.map(RemoteScoreRevisionWireV1.int64Bytes));tlv(&nested,7,day.serverSequence.map(RemoteScoreRevisionWireV1.int64Bytes));tlv(&data,UInt8(10+day.ordinal),nested) }
        return SHA256Digest.hexDigest(data)
    }
    public static func resultHash(competitionID:UUID,participantA:UUID,totalA:Int,commitmentA:String,participantB:UUID,totalB:Int,commitmentB:String,outcome:String,winner:UUID?,basis:String)throws->String {
        let nilID=UUID(uuidString:"00000000-0000-0000-0000-000000000000")!
        let identitiesOK=competitionID != nilID && participantA != nilID && participantB != nilID && participantA != participantB && RemoteScoreRevisionWireV1.uuidBytes(participantA).lexicographicallyPrecedes(RemoteScoreRevisionWireV1.uuidBytes(participantB))
        let outcomeOK=(outcome=="tie" && totalA==totalB && winner==nil)||(outcome=="winner" && totalA != totalB && winner == (totalA>totalB ? participantA:participantB))
        guard identitiesOK,outcomeOK,(0...420000).contains(totalA),(0...420000).contains(totalB),["stable","best_available"].contains(basis),let ca=try digest(commitmentA),let cb=try digest(commitmentB) else { throw ValidationError.invalidResult }
        var data=Data("healthcomp-result-v1\0".utf8);tlv(&data,1,RemoteScoreRevisionWireV1.uuidBytes(competitionID));tlv(&data,2,RemoteScoreRevisionWireV1.uuidBytes(participantA));tlv(&data,3,RemoteScoreRevisionWireV1.int32Bytes(totalA));tlv(&data,4,ca);tlv(&data,5,RemoteScoreRevisionWireV1.uuidBytes(participantB));tlv(&data,6,RemoteScoreRevisionWireV1.int32Bytes(totalB));tlv(&data,7,cb);tlv(&data,8,Data(outcome.utf8));tlv(&data,9,winner.map(RemoteScoreRevisionWireV1.uuidBytes));tlv(&data,10,Data(basis.utf8));return SHA256Digest.hexDigest(data)
    }
    private static func digest(_ value:String?)throws->Data?{guard let value else{return nil};guard value.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil else{throw ValidationError.invalidWindow};var bytes:[UInt8]=[];var i=value.startIndex;while i<value.endIndex{let n=value.index(i,offsetBy:2);bytes.append(UInt8(value[i..<n],radix:16)!);i=n};return Data(bytes)}
    private static func tlv(_ data:inout Data,_ tag:UInt8,_ payload:Data?){data.append(tag);if let payload{var n=UInt32(payload.count).bigEndian;data.append(Swift.withUnsafeBytes(of:&n){Data($0)});data.append(payload)}else{data.append(Data(repeating:0xff,count:4))}}
}
