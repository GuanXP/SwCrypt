import Foundation
import CommonCrypto

enum SwError : ErrorType {
	case Base64Decoding
	case UTF8Decoding
	case ASN1Parse
	case PEMParse
	case SEMParse
	case SEMUnsupportedVersion
	case SEMMessageAuthentication
}

enum SecError : OSStatus, ErrorType {
	case Unimplemented = -4
	case Param = -50
	case Allocate = -108
	case NotAvailable = -25291
	case AuthFailed = -25293
	case DuplicateItem = -25299
	case ItemNotFound = -25300
	case InteractionNotAllowed = -25308
	case Decode = -26275
	case Unknown = -2147483648
	init(status: OSStatus) {
		self = SecError(rawValue: status) ?? .Unknown
	}
	static func check(status: OSStatus) throws {
		guard status == errSecSuccess else {
			throw SecError(status: status)
		}
	}
}

public class SwKeyStore {
	
	static public func upsertKey(pemKey: String, keyTag: String,
	                             options: [NSString : AnyObject] = [:]) throws {
		let pemKeyAsData = pemKey.dataUsingEncoding(NSUTF8StringEncoding)!
		
		var parameters :[NSString : AnyObject] = [
			kSecClass : kSecClassKey,
			kSecAttrKeyType : kSecAttrKeyTypeRSA,
			kSecAttrIsPermanent: true,
			kSecAttrApplicationTag: keyTag,
			kSecValueData: pemKeyAsData
		]
		options.forEach({k, v in parameters[k] = v})
		
		var status = SecItemAdd(parameters, nil)
		if status == errSecDuplicateItem {
			try delKey(keyTag)
			status = SecItemAdd(parameters, nil)
		}
		try SecError.check(status)
	}
	
	static public func getKey(keyTag: String) throws -> String {
		let parameters: [NSString : AnyObject] = [
			kSecClass : kSecClassKey,
			kSecAttrKeyType : kSecAttrKeyTypeRSA,
			kSecAttrApplicationTag : keyTag,
			kSecReturnData : true
		]
		var data: AnyObject?
		try SecError.check(SecItemCopyMatching(parameters, &data))
		guard let pemKeyAsData = data as? NSData else {
			throw SwError.UTF8Decoding
		}
		guard let result = String(data: pemKeyAsData, encoding: NSUTF8StringEncoding) else {
			throw SwError.UTF8Decoding
		}
		return result
	}
	
	static public func delKey(keyTag: String) throws {
		let parameters: [NSString : AnyObject] = [
			kSecClass : kSecClassKey,
			kSecAttrApplicationTag: keyTag
		]
		try SecError.check(SecItemDelete(parameters))
	}
}

public class SwPrivateKey {
	
	static public func pemToPKCS1DER(pemKey: String) throws -> NSData {
		let derKey = try PEM.PrivateKey.toDER(pemKey)
		return try PKCS8.PrivateKey.stripHeaderIfAny(derKey)
	}
	
	static public func derToPKCS1PEM(derKey: NSData) -> String {
		return PEM.PrivateKey.toPEM(derKey)
	}

}

public class SwPublicKey {
	
	static public func pemToPKCS1DER(pemKey: String) throws -> NSData {
		let derKey = try PEM.PublicKey.toDER(pemKey)
		return try PKCS8.PublicKey.stripHeaderIfAny(derKey)
	}
	
	static public func derToPKCS1PEM(derKey: NSData) -> String {
		return PEM.PublicKey.toPEM(derKey)
	}
	
	static public func derToPKCS8PEM(derKey: NSData) -> String {
		let pkcs8Key = PKCS8.PublicKey.addHeader(derKey)
		return PEM.PublicKey.toPEM(pkcs8Key)
	}
	
}

public class SwEncryptedPrivateKey {
	public enum Mode {
		case AES128CBC, AES256CBC
	}
	
	static public func encryptPEM(pemKey: String, passphrase: String, mode: Mode) throws -> String {
		let derKey = try PEM.PrivateKey.toDER(pemKey)
		return try PEM.EncryptedPrivateKey.toPEM(derKey, passphrase: passphrase, mode: mode)
	}
	
	static public func decryptPEM(pemKey: String, passphrase: String) throws -> String {
		let derKey = try PEM.EncryptedPrivateKey.toDER(pemKey, passphrase: passphrase)
		return PEM.PrivateKey.toPEM(derKey)
	}
	
}

private class PKCS8 {
	
	private class PrivateKey {
		
		//https://lapo.it/asn1js/
		static private func stripHeaderIfAny(derKey: NSData) throws -> NSData {
			var bytes = derKey.arrayOfBytes()
			
			var offset = 0
			guard bytes[offset] == 0x30 else {
				throw SwError.ASN1Parse
			}
			offset += 1
			
			if bytes[offset] > 0x80 {
				offset += Int(bytes[offset]) - 0x80
			}
			offset += 1
			
			guard bytes[offset] == 0x02 else {
				throw SwError.ASN1Parse
			}
			offset += 3
			
			//without PKCS8 header
			if bytes[offset] == 0x02 {
				return derKey
			}
			
			let OID: [UInt8] = [0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
			                    0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00]
			let slice: [UInt8] = Array(bytes[offset..<(offset + OID.count)])
			
			guard slice == OID else {
				throw SwError.ASN1Parse
			}
			
			offset += OID.count
			guard bytes[offset] == 0x04 else {
				throw SwError.ASN1Parse
			}
			
			offset += 1
			if bytes[offset] > 0x80 {
				offset += Int(bytes[offset]) - 0x80
			}
			offset += 1
			
			guard bytes[offset] == 0x30 else {
				throw SwError.ASN1Parse
			}
			
			return derKey.subdataWithRange(NSRange(location: offset, length: derKey.length - offset))
		}
	}
	
	class PublicKey {
		
		static private func addHeader(derKey: NSData) -> NSData {
			let result = NSMutableData()
			
			let encodingLength: Int = encodedOctets(derKey.length + 1).count
			let OID: [UInt8] = [0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
			                    0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00]
			
			var builder: [UInt8] = []
			
			// ASN.1 SEQUENCE
			builder.append(0x30)
			
			// Overall size, made of OID + bitstring encoding + actual key
			let size = OID.count + 2 + encodingLength + derKey.length
			let encodedSize = encodedOctets(size)
			builder.appendContentsOf(encodedSize)
			result.appendBytes(builder, length: builder.count)
			result.appendBytes(OID, length: OID.count)
			builder.removeAll(keepCapacity: false)
			
			builder.append(0x03)
			builder.appendContentsOf(encodedOctets(derKey.length + 1))
			builder.append(0x00)
			result.appendBytes(builder, length: builder.count)
			
			// Actual key bytes
			result.appendData(derKey)
			
			return result as NSData
		}
		
		//https://lapo.it/asn1js/
		static private func stripHeaderIfAny(derKey: NSData) throws -> NSData {
			var bytes = derKey.arrayOfBytes()
			
			var offset = 0
			guard bytes[offset] == 0x30 else {
				throw SwError.ASN1Parse
			}
			
			offset += 1
			
			if bytes[offset] > 0x80 {
				offset += Int(bytes[offset]) - 0x80
			}
			offset += 1
			
			//without PKCS8 header
			if bytes[offset] == 0x02 {
				return derKey
			}
			
			let OID: [UInt8] = [0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
			                    0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00]
			let slice: [UInt8] = Array(bytes[offset..<(offset + OID.count)])
			
			guard slice == OID else {
				throw SwError.ASN1Parse
			}
			
			offset += OID.count
			
			// Type
			guard bytes[offset] == 0x03 else {
				throw SwError.ASN1Parse
			}
			
			offset += 1
			
			if bytes[offset] > 0x80 {
				offset += Int(bytes[offset]) - 0x80
			}
			offset += 1
			
			// Contents should be separated by a null from the header
			guard bytes[offset] == 0x00 else {
				throw SwError.ASN1Parse
			}
			
			offset += 1
			return derKey.subdataWithRange(NSRange(location: offset, length: derKey.length - offset))
		}
		
		static private func encodedOctets(int: Int) -> [UInt8] {
			// Short form
			if int < 128 {
				return [UInt8(int)];
			}
			
			// Long form
			let i = (int / 256) + 1
			var len = int
			var result: [UInt8] = [UInt8(i + 0x80)]
			
			for _ in 0..<i {
				result.insert(UInt8(len & 0xFF), atIndex: 1)
				len = len >> 8
			}
			
			return result
		}
	}
}

private class PEM {
	
	private class PrivateKey {
		
		static private func toDER(pemKey: String) throws -> NSData {
			let strippedKey = try stripHeader(pemKey)
			guard let data = NSData(base64EncodedString: strippedKey, options: [.IgnoreUnknownCharacters]) else {
				throw SwError.Base64Decoding
			}
			return data
		}
		
		static private func toPEM(derKey: NSData) -> String {
			let base64 = derKey.base64EncodedStringWithOptions(
				[.Encoding64CharacterLineLength,.EncodingEndLineWithLineFeed])
			return addRSAHeader(base64)
		}
		
		static private let Prefix = "-----BEGIN PRIVATE KEY-----\n"
		static private let Suffix = "\n-----END PRIVATE KEY-----"
		static private let RSAPrefix = "-----BEGIN RSA PRIVATE KEY-----\n"
		static private let RSASuffix = "\n-----END RSA PRIVATE KEY-----"
		
		static private func addHeader(base64: String) -> String {
			return Prefix + base64 + Suffix
		}
		
		static private func addRSAHeader(base64: String) -> String {
			return RSAPrefix + base64 + RSASuffix
		}
		
		static private func stripHeader(pemKey: String) throws -> String {
			if pemKey.hasPrefix(Prefix) {
				guard let r = pemKey.rangeOfString(Suffix) else {
					throw SwError.PEMParse
				}
				return pemKey.substringWithRange(Prefix.endIndex..<r.startIndex)
			}
			if pemKey.hasPrefix(RSAPrefix) {
				guard let r = pemKey.rangeOfString(RSASuffix) else {
					throw SwError.PEMParse
				}
				return pemKey.substringWithRange(RSAPrefix.endIndex..<r.startIndex)
			}
			throw SwError.PEMParse
		}
	}
	
	private class PublicKey {
		
		static private func toDER(pemKey: String) throws -> NSData {
			let strippedKey = try stripHeader(pemKey)
			guard let data = NSData(base64EncodedString: strippedKey,
			                        options: [.IgnoreUnknownCharacters]) else {
										throw SwError.Base64Decoding
			}
			return data
		}
		
		static private func toPEM(derKey: NSData) -> String {
			let base64 = derKey.base64EncodedStringWithOptions(
				[.Encoding64CharacterLineLength,.EncodingEndLineWithLineFeed])
			return addHeader(base64)
		}
		
		static private let PEMPrefix = "-----BEGIN PUBLIC KEY-----\n"
		static private let PEMSuffix = "\n-----END PUBLIC KEY-----"
		
		static private func addHeader(base64: String) -> String {
			return PEMPrefix + base64 + PEMSuffix
		}
		
		static private func stripHeader(pemKey: String) throws -> String {
			guard pemKey.hasPrefix(PEMPrefix) else {
				throw SwError.PEMParse
			}
			guard let r = pemKey.rangeOfString(PEMSuffix) else {
				throw SwError.PEMParse
			}
			return pemKey.substringWithRange(PEMPrefix.endIndex..<r.startIndex)
		}
	}
	
	private class EncryptedPrivateKey {
		typealias Mode = SwEncryptedPrivateKey.Mode
		
		static private func toDER(pemKey: String, passphrase: String) throws -> NSData {
			let strippedKey = try PEM.PrivateKey.stripHeader(pemKey)
			return try decryptPEM(strippedKey, passphrase: passphrase)
		}
		
		static private func toPEM(derKey: NSData, passphrase: String, mode: Mode) throws -> String {
			let encryptedDERKey = try encryptDERKey(derKey, passphrase: passphrase, mode: mode)
			return PEM.PrivateKey.addRSAHeader(encryptedDERKey)
		}
		
		static private let AES128CBCInfo = "Proc-Type: 4,ENCRYPTED\nDEK-Info: AES-128-CBC,"
		static private let AES256CBCInfo = "Proc-Type: 4,ENCRYPTED\nDEK-Info: AES-256-CBC,"
		static private let AESInfoLength = AES128CBCInfo.characters.count
		static private let AESIVInHexLength = 32
		static private let AESHeaderLength = AESInfoLength + AESIVInHexLength
		
		static private func encryptDERKeyAES128CBC(derKey: NSData, passphrase: String) throws -> String {
			let iv = try CC.generateRandom(16)
			let aesKey = getAES128Key(passphrase, iv: iv)
			let encrypted = try CC.crypt(.encrypt, blockMode: .CBC, algorithm: .AES, padding: .PKCS7Padding, data: derKey, key: aesKey, iv: iv)
			return AES128CBCInfo + iv.hexadecimalString() + "\n\n" +
				encrypted.base64EncodedStringWithOptions(
					[.Encoding64CharacterLineLength,.EncodingEndLineWithLineFeed])
		}
		
		static private func encryptDERKeyAES256CBC(derKey: NSData, passphrase: String) throws -> String {
			let iv = try CC.generateRandom(16)
			let aesKey = getAES256Key(passphrase, iv: iv)
			let encrypted = try CC.crypt(.encrypt, blockMode: .CBC, algorithm: .AES, padding: .PKCS7Padding, data: derKey, key: aesKey, iv: iv)
			return AES256CBCInfo + iv.hexadecimalString() + "\n\n" +
				encrypted.base64EncodedStringWithOptions(
					[.Encoding64CharacterLineLength,.EncodingEndLineWithLineFeed])
		}
		
		static private func encryptDERKey(derKey: NSData, passphrase: String, mode: Mode) throws -> String {
			switch mode {
			case .AES128CBC: return try encryptDERKeyAES128CBC(derKey, passphrase: passphrase)
			case .AES256CBC: return try encryptDERKeyAES256CBC(derKey, passphrase: passphrase)
			}
		}
		
		static private func decryptPEM(strippedKey: String, passphrase: String) throws -> NSData {
			let iv = try getIV(strippedKey)
			let aesKey = try getAESKey(strippedKey, passphrase: passphrase, iv: iv)
			let base64Data = strippedKey.substringFromIndex(strippedKey.startIndex+AESHeaderLength)
			guard let data = NSData(base64EncodedString: base64Data,
			                        options: [.IgnoreUnknownCharacters]) else {
										throw SwError.Base64Decoding
			}
			let decrypted = try CC.crypt(.decrypt, blockMode: .CBC, algorithm: .AES, padding: .PKCS7Padding, data: data, key: aesKey, iv: iv)
			return decrypted
		}
		
		static private func getIV(strippedKey: String) throws -> NSData {
			let ivInHex = strippedKey.substringWithRange(strippedKey.startIndex+AESInfoLength..<strippedKey.startIndex+AESHeaderLength)
			guard let iv = ivInHex.dataFromHexadecimalString() else {
				throw SwError.PEMParse
			}
			return iv
		}
		
		static private func getAESKey(strippedKey: String, passphrase: String, iv: NSData) throws -> NSData {
			if strippedKey.hasPrefix(AES128CBCInfo) {
				return getAES128Key(passphrase, iv: iv)
			}
			if strippedKey.hasPrefix(AES256CBCInfo) {
				return getAES256Key(passphrase, iv: iv)
			}
			throw SwError.PEMParse
		}
		
		static private func getAES128Key(passphrase: String, iv: NSData) -> NSData {
			//128bit_Key = MD5(Passphrase + Salt)
			let pass = passphrase.dataUsingEncoding(NSUTF8StringEncoding)!
			let salt = iv.subdataWithRange(NSRange(location: 0, length: 8))
			
			let key = NSMutableData()
			key.appendData(pass)
			key.appendData(salt)
			return CC.md5(key)
		}
		
		static private func getAES256Key(passphrase: String, iv: NSData) -> NSData {
			//128bit_Key = MD5(Passphrase + Salt)
			//256bit_Key = 128bit_Key + MD5(128bit_Key + Passphrase + Salt)
			let pass = passphrase.dataUsingEncoding(NSUTF8StringEncoding)!
			let salt = iv.subdataWithRange(NSRange(location: 0, length: 8))
			
			let first = NSMutableData()
			first.appendData(pass)
			first.appendData(salt)
			let aes128Key = CC.md5(first)
			
			let sec = NSMutableData()
			sec.appendData(aes128Key)
			sec.appendData(pass)
			sec.appendData(salt)
			
			let aes256Key = NSMutableData()
			aes256Key.appendData(aes128Key)
			aes256Key.appendData(CC.md5(sec))
			return aes256Key
		}
		
	}
	
}


//Simple Encrypted Message
public class SEM {
	
	public enum AESMode : UInt8 {
		case AES128, AES192, AES256
		
		var keySize: Int {
			switch self {
			case .AES128: return 16
			case .AES192: return 24
			case .AES256: return 32
			}
		}
	}
	
	public enum BlockMode : UInt8 {
		case CBC, GCM
		
		var ivSize: Int {
			switch self {
			case .CBC: return 16
			case .GCM: return 12
			}
		}
		var cc: CC.BlockMode {
			switch self {
			case .CBC: return .CBC
			case .GCM: return .GCM
			}
		}
	}
	
	public enum HMACMode : UInt8 {
		case None, SHA256, SHA512
		
		var cc: CC.HMACAlg?  {
			switch self {
			case .None: return nil
			case .SHA256: return .SHA256
			case .SHA512: return .SHA512
			}
		}
		var digestLength: Int {
			switch self {
			case .None: return 0
			default: return self.cc!.digestLength
			}
		}

	}
	
	public struct Mode {
		let version : UInt8 = 0
		let aes: AESMode
		let block: BlockMode
		let hmac: HMACMode
		public init() {
			aes = .AES256
			block = .CBC
			hmac = .SHA256
		}
		public init(aes: AESMode, block: BlockMode, hmac: HMACMode) {
			self.aes = aes
			self.block = block
			self.hmac = hmac
		}
	}
	
	static public func encryptMessage(message: String, pemKey: String, mode: Mode) throws -> String {
		let data = message.dataUsingEncoding(NSUTF8StringEncoding)!
		let encryptedData = try encryptData(data, pemKey: pemKey, mode: mode)
		return encryptedData.base64EncodedStringWithOptions([])
	}
	
	static public func decryptMessage(message: String, pemKey: String) throws -> String {
		guard let data = NSData(base64EncodedString: message, options: []) else {
			throw SwError.Base64Decoding
		}
		let decryptedData = try decryptData(data, pemKey: pemKey)
		guard let decryptedString = String(data: decryptedData, encoding: NSUTF8StringEncoding) else {
			throw SwError.UTF8Decoding
		}
		return decryptedString
	}
	
	static public func encryptData(data: NSData, pemKey: String, mode: Mode) throws -> NSData {
		let aesKey = try CC.generateRandom(mode.aes.keySize)
		let iv = try CC.generateRandom(mode.block.ivSize)
		let header = getMessageHeader(mode, aesKey: aesKey, iv: iv)
		let derKey = try SwPublicKey.pemToPKCS1DER(pemKey)
		
		let encryptedHeader = try CCRSA.encrypt(header, derKey: derKey, padding: .OAEP, digest: .SHA1)
		let encryptedData = try CC.crypt(.encrypt, blockMode: mode.block.cc,
		                                 algorithm: .AES, padding: .PKCS7Padding,
		                                 data: data, key: aesKey, iv: iv)
		
		let result = NSMutableData()
		result.appendData(encryptedHeader)
		result.appendData(encryptedData)
		if mode.hmac != .None {
			result.appendData(CC.HMAC(result, alg: mode.hmac.cc!, key: aesKey))
		}
		return result
	}
	
	
	static public func decryptData(data: NSData, pemKey: String) throws -> NSData {
		let derKey = try SwPrivateKey.pemToPKCS1DER(pemKey)
		let (header, tail) =  try CCRSA.decrypt(data, derKey: derKey, padding: .OAEP, digest: .SHA1)
		let (mode, aesKey, iv) = try parseMessageHeader(header)
		
		try checkHMAC(data, aesKey: aesKey, mode: mode.hmac)
		let encryptedData = tail.subdataWithRange(NSRange(location: 0, length: tail.length - mode.hmac.digestLength))
		return try CC.crypt(.decrypt, blockMode: mode.block.cc, algorithm: .AES, padding: .PKCS7Padding, data: encryptedData, key: aesKey, iv: iv)
	}
	
	static private func checkHMAC(data: NSData, aesKey: NSData, mode: SEM.HMACMode) throws {
		if mode != .None {
			let hmaccedData = data.subdataWithRange(NSRange(location: 0, length: data.length - mode.digestLength))
			let hmac = data.subdataWithRange(NSRange(location: data.length - mode.digestLength, length: mode.digestLength))
			guard CC.HMAC(hmaccedData, alg: mode.cc!, key: aesKey) == hmac else {
				throw SwError.SEMMessageAuthentication
			}
		}
	}
	
	static private func getMessageHeader(mode: Mode, aesKey: NSData, iv: NSData) -> NSData {
		let header : [UInt8] = [mode.version, mode.aes.rawValue, mode.block.rawValue, mode.hmac.rawValue]
		let message = NSMutableData(bytes: header, length: 4)
		message.appendData(aesKey)
		message.appendData(iv)
		return message
	}
	
	static private func parseMessageHeader(header: NSData) throws -> (Mode, NSData, NSData) {
		guard header.length > 4 else {
			throw SwError.SEMParse
		}
		let bytes = header.arrayOfBytes()
		let version = bytes[0]
		guard version == 0 else {
			throw SwError.SEMUnsupportedVersion
		}
		guard let aes = AESMode(rawValue: bytes[1]) else {
			throw SwError.SEMParse
		}
		guard let block = BlockMode(rawValue: bytes[2]) else {
			throw SwError.SEMParse
		}
		guard let hmac = HMACMode(rawValue: bytes[3]) else {
			throw SwError.SEMParse
		}
		let keySize = aes.keySize
		let ivSize = block.ivSize
		guard header.length == 4 + keySize + ivSize else {
			throw SwError.SEMParse
		}
		let key = header.subdataWithRange(NSRange(location: 4, length: keySize))
		let iv = header.subdataWithRange(NSRange(location: 4 + keySize, length: ivSize))
		
		return (Mode(aes: aes, block: block, hmac: hmac), key, iv)
	}	
}

public enum CCError : CCCryptorStatus, ErrorType {
	case ParamError = -4300
	case BufferTooSmall = -4301
	case MemoryFailure = -4302
	case AlignmentError = -4303
	case DecodeError = -4304
	case Unimplemented = -4305
	case Overflow = -4306
	case RNGFailure = -4307
	case NotAvailable = -2147483647
	case Unknown = -2147483648
	init(status: CCCryptorStatus) {
		self = CCError(rawValue: status) ?? .Unknown
	}
	static func check(status: CCCryptorStatus) throws {
		guard status == noErr else {
			throw CCError(status: status)
		}
	}
	static func check(status: CCCryptorStatus?) throws {
		try check(status ?? NotAvailable.rawValue)
	}
}

public class CC {
	
	static public func generateRandom(size: Int) throws -> NSData {
		let data = NSMutableData(length: size)!
		try CCError.check(CCRandomGenerateBytes(data.mutableBytes, size))
		return data
	}
	
	static public func sha1(data: NSData) -> NSData {
		let result = NSMutableData(length: Int(CC_SHA1_DIGEST_LENGTH))!
		CC_SHA1(data.bytes, CC_LONG(data.length), UnsafeMutablePointer<UInt8>(result.mutableBytes))
		return result
	}
	
	static public func sha256(data: NSData) -> NSData {
		let result = NSMutableData(length: Int(CC_SHA256_DIGEST_LENGTH))!
		CC_SHA256(data.bytes, CC_LONG(data.length), UnsafeMutablePointer<UInt8>(result.mutableBytes))
		return result
	}
	
	static public func sha384(data: NSData) -> NSData {
		let result = NSMutableData(length: Int(CC_SHA384_DIGEST_LENGTH))!
		CC_SHA384(data.bytes, CC_LONG(data.length), UnsafeMutablePointer<UInt8>(result.mutableBytes))
		return result
	}
	
	static public func sha512(data: NSData) -> NSData {
		let result = NSMutableData(length: Int(CC_SHA512_DIGEST_LENGTH))!
		CC_SHA512(data.bytes, CC_LONG(data.length), UnsafeMutablePointer<UInt8>(result.mutableBytes))
		return result
	}
	
	static public func sha224(data: NSData) -> NSData {
		let result = NSMutableData(length: Int(CC_SHA224_DIGEST_LENGTH))!
		CC_SHA224(data.bytes, CC_LONG(data.length), UnsafeMutablePointer<UInt8>(result.mutableBytes))
		return result
	}
	
	static public func md5(data: NSData) -> NSData {
		let result = NSMutableData(length: Int(CC_MD5_DIGEST_LENGTH))!
		CC_MD5(data.bytes, CC_LONG(data.length), UnsafeMutablePointer<UInt8>(result.mutableBytes))
		return result
	}
	
	public enum HMACAlg : CCHmacAlgorithm {
		case SHA1, MD5, SHA256, SHA384, SHA512, SHA224
		
		var digestLength: Int {
			switch self {
			case .SHA1: return Int(CC_SHA1_DIGEST_LENGTH)
			case .MD5: return Int(CC_MD5_DIGEST_LENGTH)
			case .SHA256: return Int(CC_SHA256_DIGEST_LENGTH)
			case .SHA384: return Int(CC_SHA384_DIGEST_LENGTH)
			case .SHA512: return Int(CC_SHA512_DIGEST_LENGTH)
			case .SHA224: return Int(CC_SHA224_DIGEST_LENGTH)
			}
		}
	}

	static public func HMAC(data: NSData, alg: HMACAlg, key: NSData) -> NSData {
		let buffer = NSMutableData(length: alg.digestLength)!
		CCHmac(alg.rawValue, key.bytes, key.length, data.bytes, data.length, buffer.mutableBytes)
		return buffer
	}
	
	public enum OpMode : CCOperation{
		case encrypt = 0, decrypt
	}
	
	public enum BlockMode : CCMode {
		case ECB = 1, CBC, CFB, CTR, F8, LRW, OFB, XTS, RC4, CFB8, GCM
	}
	
	public enum Algorithm : CCAlgorithm {
		case AES = 0, mDES, _3DES, CAST, RC4, RC2, Blowfish
	}
	
	public enum Padding : CCPadding {
		case NoPadding = 0, PKCS7Padding
	}
	
	static public func crypt(opMode: OpMode, blockMode: BlockMode,
	                            algorithm: Algorithm, padding: Padding,
	                            data: NSData, key: NSData, iv: NSData) throws -> NSData {
		if blockMode == .GCM {
			let (result,tag) = try CCGCM.crypt(opMode, algorithm: algorithm, data: data, key: key, iv: iv)
			return result
		}
		var cryptor : CCCryptorRef = nil
		try CCError.check(CCCryptorCreateWithMode(
			opMode.rawValue, blockMode.rawValue,
			algorithm.rawValue, padding.rawValue,
			iv.bytes, key.bytes, key.length, nil, 0, 0,	CCModeOptions(), &cryptor))
		defer { CCCryptorRelease(cryptor) }
		
		let needed = CCCryptorGetOutputLength(cryptor, data.length, true)
		let result = NSMutableData(length: needed)!
		var updateLen: size_t = 0
		try CCError.check(CCCryptorUpdate(cryptor, data.bytes, data.length,
			result.mutableBytes, result.length, &updateLen))
		
		var finalLen: size_t = 0
		try CCError.check(CCCryptorFinal(cryptor, result.mutableBytes + updateLen,
			result.length - updateLen, &finalLen))
		
		result.length = updateLen + finalLen
		return result
	}
	
	static private let dl = dlopen("/usr/lib/system/libcommonCrypto.dylib", RTLD_NOW)
}

func getFunc<T>(from: UnsafeMutablePointer<Void>, f: String) -> T? {
	let sym = dlsym(from, f)
	guard sym != nil else {
		return nil
	}
	return unsafeBitCast(sym, T.self)
}

public class CCGCM {
	
	static public func crypt(opMode: CC.OpMode, algorithm: CC.Algorithm, data: NSData,
	                            key: NSData, iv: NSData) throws -> (NSData, NSData) {
		let result = NSMutableData(length: data.length)!
		var tagLength = 16
		let tag = NSMutableData(length: tagLength)!
		try CCError.check(CCCryptorGCM?(op: opMode.rawValue, alg: algorithm.rawValue,
			key: key.bytes, keyLength: key.length, iv: iv.bytes, ivLen: iv.length,
			aData: nil, aDataLen: 0, dataIn: data.bytes, dataInLength: data.length,
			dataOut: result.mutableBytes, tag: tag.bytes, tagLength: &tagLength))
		tag.length = tagLength
		return (result, tag)
	}
	
	static public func available() -> Bool {
		if CCCryptorGCM != nil {
			return true
		}
		return false
	}
	
	typealias CCCryptorGCMT = @convention(c) (op: CCOperation, alg: CCAlgorithm, key: UnsafePointer<Void>, keyLength: Int, iv: UnsafePointer<Void>, ivLen: Int, aData: UnsafePointer<Void>, aDataLen: Int, dataIn: UnsafePointer<Void>, dataInLength: Int, dataOut: UnsafeMutablePointer<Void>, tag: UnsafePointer<Void>, tagLength: UnsafeMutablePointer<Int>) -> CCCryptorStatus
	static private let CCCryptorGCM : CCCryptorGCMT? = getFunc(CC.dl, f: "CCCryptorGCM")
}

public class CCRSA {
	
	public typealias CCAsymmetricPadding = UInt32
	public typealias CCDigestAlgorithm = UInt32
	typealias CCRSACryptorRef = UnsafePointer<Void>
	
	public enum AsymmetricPadding : CCAsymmetricPadding {
		case PKCS1 = 1001
		case OAEP = 1002
	}
	
	public enum DigestAlgorithm : CCDigestAlgorithm {
		case None = 0
		case SHA1 = 8
		case SHA224 = 9
		case SHA256 = 10
		case SHA384 = 11
		case SHA512 = 12
	}
	
	static public func generateKeyPair(keySize: Int = 4096) throws -> (NSData, NSData) {
		var privateKey: CCRSACryptorRef = nil
		var publicKey: CCRSACryptorRef = nil
		try CCError.check(CCRSACryptorGeneratePair?(
			keySize: keySize,
			e: 65537,
			publicKey: &publicKey,
			privateKey: &privateKey))

		defer {
			CCRSACryptorRelease?(privateKey)
			CCRSACryptorRelease?(publicKey)
		}
		
		let privDERKey = try exportToDERKey(privateKey)
		let pubDERKey = try exportToDERKey(publicKey)
		
		return (privDERKey, pubDERKey)
	}
	
	static public func encrypt(data: NSData, derKey: NSData, padding: AsymmetricPadding,
	                           digest: DigestAlgorithm) throws -> NSData {
		let key = try importFromDERKey(derKey)
		defer { CCRSACryptorRelease?(key) }
		
		var bufferSize = try getKeySize(key)
		let buffer = NSMutableData(length: bufferSize)!
		
		try CCError.check(CCRSACryptorEncrypt?(
			publicKey: key,
			padding: padding.rawValue,
			plainText: data.bytes,
			plainTextLen: data.length,
			cipherText: buffer.mutableBytes,
			cipherTextLen: &bufferSize,
			tagData: nil, tagDataLen: 0,
			digestType: digest.rawValue))
		
		return buffer
	}
	
	static public func decrypt(data: NSData, derKey: NSData, padding: AsymmetricPadding,
	                           digest: DigestAlgorithm) throws -> (NSData, NSData) {
		let key = try importFromDERKey(derKey)
		defer { CCRSACryptorRelease?(key) }
		
		let blockSize = try getKeySize(key)
		
		guard data.length >= blockSize else {
			throw CCError.DecodeError
		}
		
		var bufferSize = blockSize
		let buffer = NSMutableData(length: bufferSize)!
		
		try CCError.check(CCRSACryptorDecrypt?(
			privateKey: key,
			padding: padding.rawValue,
			cipherText: data.bytes,
			cipherTextLen: bufferSize,
			plainText: buffer.mutableBytes,
			plainTextLen: &bufferSize,
			tagData: nil, tagDataLen: 0,
			digestType: digest.rawValue))

		buffer.length = bufferSize
		let tail = data.subdataWithRange(NSRange(location: blockSize, length: data.length - blockSize))
		return (buffer, tail)
	}
	
	static private func importFromDERKey(derKey: NSData) throws -> CCRSACryptorRef {
		var key : CCRSACryptorRef = nil
		try CCError.check(CCRSACryptorImport?(
			keyPackage: derKey.bytes,
			keyPackageLen: derKey.length,
			key: &key))
		return key
	}
	
	static private func exportToDERKey(key: CCRSACryptorRef) throws -> NSData {
		var derKeyLength = 8192
		let derKey = NSMutableData(length: derKeyLength)!
		try CCError.check(CCRSACryptorExport?(
			key: key,
			out: derKey.mutableBytes,
			outLen: &derKeyLength))
		derKey.length = derKeyLength
		return derKey
	}
	
	static private func getKeySize(key: CCRSACryptorRef) throws -> Int {
		guard let keySize = CCRSAGetKeySize?(key) else {
			throw CCError.NotAvailable
		}
		return Int(keySize/8)
	}
	
	static public func available() -> Bool {
		if CCRSACryptorGeneratePair != nil &&
			CCRSACryptorRelease != nil &&
			CCRSAGetKeySize != nil &&
			CCRSACryptorEncrypt != nil &&
			CCRSACryptorDecrypt != nil &&
			CCRSACryptorExport != nil &&
			CCRSACryptorImport != nil {
			return true
		}
		return false
	}
	
	typealias CCRSACryptorGeneratePairT = @convention(c) (
		keySize: Int,
		e: UInt32,
		publicKey: UnsafeMutablePointer<CCRSACryptorRef>,
		privateKey: UnsafeMutablePointer<CCRSACryptorRef>) -> CCCryptorStatus
	static private let CCRSACryptorGeneratePair : CCRSACryptorGeneratePairT? =
		getFunc(CC.dl, f: "CCRSACryptorGeneratePair")
	
	typealias CCRSACryptorReleaseT = @convention(c) (CCRSACryptorRef) -> Void
	static let CCRSACryptorRelease : CCRSACryptorReleaseT? = getFunc(CC.dl, f: "CCRSACryptorRelease")
	
	typealias CCRSAGetKeySizeT = @convention(c) (CCRSACryptorRef) -> Int32
	static let CCRSAGetKeySize : CCRSAGetKeySizeT? = getFunc(CC.dl, f: "CCRSAGetKeySize")
	
	typealias CCRSACryptorEncryptT = @convention(c) (
		publicKey: CCRSACryptorRef,
		padding: CCAsymmetricPadding,
		plainText: UnsafePointer<Void>,
		plainTextLen: Int,
		cipherText: UnsafeMutablePointer<Void>,
		cipherTextLen: UnsafeMutablePointer<Int>,
		tagData: UnsafePointer<Void>,
		tagDataLen: Int,
		digestType: CCDigestAlgorithm) -> CCCryptorStatus
	static let CCRSACryptorEncrypt : CCRSACryptorEncryptT? = getFunc(CC.dl, f: "CCRSACryptorEncrypt")
	
	typealias CCRSACryptorDecryptT = @convention (c) (
		privateKey: CCRSACryptorRef,
		padding: CCAsymmetricPadding,
		cipherText: UnsafePointer<Void>,
		cipherTextLen: Int,
		plainText: UnsafeMutablePointer<Void>,
		plainTextLen: UnsafeMutablePointer<Int>,
		tagData: UnsafePointer<Void>,
		tagDataLen: Int,
		digestType: CCDigestAlgorithm) -> CCCryptorStatus
	static let CCRSACryptorDecrypt : CCRSACryptorDecryptT? = getFunc(CC.dl, f: "CCRSACryptorDecrypt")
	
	typealias CCRSACryptorExportT = @convention(c) (
		key: CCRSACryptorRef,
		out: UnsafeMutablePointer<Void>,
		outLen: UnsafeMutablePointer<Int>) -> CCCryptorStatus
	static let CCRSACryptorExport : CCRSACryptorExportT? = getFunc(CC.dl, f: "CCRSACryptorExport")
	
	typealias CCRSACryptorImportT = @convention(c) (
		keyPackage: UnsafePointer<Void>,
		keyPackageLen: Int,
		key: UnsafeMutablePointer<CCRSACryptorRef>) -> CCCryptorStatus
	static let CCRSACryptorImport : CCRSACryptorImportT? = getFunc(CC.dl, f: "CCRSACryptorImport")
}


extension NSData {
	/// Create hexadecimal string representation of NSData object.
	///
	/// - returns: String representation of this NSData object.
	
	public func hexadecimalString() -> String {
		var hexstr = String()
		for i in UnsafeBufferPointer<UInt8>(start: UnsafeMutablePointer<UInt8>(bytes), count: length) {
			hexstr += String(format: "%02X", i)
		}
		return hexstr
	}
	
	public func arrayOfBytes() -> [UInt8] {
		let count = self.length / sizeof(UInt8)
		var bytesArray = [UInt8](count: count, repeatedValue: 0)
		self.getBytes(&bytesArray, length:count * sizeof(UInt8))
		return bytesArray
	}
}

extension String.CharacterView.Index : Strideable { }
extension String {
	
	/// Create NSData from hexadecimal string representation
	///
	/// This takes a hexadecimal representation and creates a NSData object. Note, if the string has any spaces, those are removed. Also if the string started with a '<' or ended with a '>', those are removed, too. This does no validation of the string to ensure it's a valid hexadecimal string
	///
	/// The use of `strtoul` inspired by Martin R at http://stackoverflow.com/a/26284562/1271826
	///
	/// - returns: NSData represented by this hexadecimal string. Returns nil if string contains characters outside the 0-9 and a-f range.
	
	public func dataFromHexadecimalString() -> NSData? {
		let trimmedString = self.stringByTrimmingCharactersInSet(NSCharacterSet(charactersInString: "<> ")).stringByReplacingOccurrencesOfString(" ", withString: "")
		
		// make sure the cleaned up string consists solely of hex digits, and that we have even number of them
		
		let regex = try! NSRegularExpression(pattern: "^[0-9a-f]*$", options: .CaseInsensitive)
		
		let found = regex.firstMatchInString(trimmedString, options: [], range: NSMakeRange(0, trimmedString.characters.count))
		guard found != nil &&
			found?.range.location != NSNotFound &&
			trimmedString.characters.count % 2 == 0 else {
				return nil
		}
		
		// everything ok, so now let's build NSData
		
		let data = NSMutableData(capacity: trimmedString.characters.count / 2)
		
		for index in trimmedString.startIndex.stride(to:trimmedString.endIndex,by:2) {
			let byteString = trimmedString.substringWithRange(index..<index.successor().successor())
			let num = UInt8(byteString.withCString { strtoul($0, nil, 16) })
			data?.appendBytes([num] as [UInt8], length: 1)
		}
		
		return data
	}
}

