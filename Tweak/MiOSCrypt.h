#import <Foundation/Foundation.h>

// A tiny BLCryptor-equivalent for encrypted on-disk storage.
//
// Format (big-endian except where noted):
//
//   [1]  version                   = 0x01
//   [16] encryption salt           (PBKDF2-SHA256 → 32-byte AES-256 key)
//   [16] HMAC salt                 (PBKDF2-SHA256 → 32-byte HMAC-SHA256 key)
//   [16] AES IV
//   […]  AES-256-CBC(PKCS7) ciphertext
//   [32] HMAC-SHA256(header + ciphertext)         ← trails the ciphertext
//
// Round count: 10,000 (PBKDF2). The password material is a device-local secret
// derived from the main bundle's identifier + a persistent per-install salt,
// so the files are not useful if copied to another sandbox but no user password
// is required.
@interface MiOSCrypt : NSObject
+ (nullable NSData *)encrypt:(nonnull NSData *)plaintext NS_SWIFT_NAME(encrypt(_:));
+ (nullable NSData *)decrypt:(nonnull NSData *)blob     NS_SWIFT_NAME(decrypt(_:));

// Returns the raw device-local password material. Lazily materialised the first
// time it is read and persisted inside Documents/miOS/.secret.
+ (nonnull NSData *)devicePassword;
@end
