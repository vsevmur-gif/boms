#import "MiOSCrypt.h"
#import "MiOSContainer.h"
#import <CommonCrypto/CommonCrypto.h>

static const uint8_t  kMiOSCryptVersion = 0x01;
static const uint32_t kMiOSPBKDFRounds  = 10000;
static const NSUInteger kSaltLen        = 16;
static const NSUInteger kIVLen          = 16;
static const NSUInteger kKeyLen         = kCCKeySizeAES256;   // 32
static const NSUInteger kHMACLen        = CC_SHA256_DIGEST_LENGTH;
static const NSUInteger kHeaderLen      = 1 + kSaltLen + kSaltLen + kIVLen;

@implementation MiOSCrypt

#pragma mark - Device password (persisted inside the app sandbox)

+ (NSData *)devicePassword {
    static dispatch_once_t once;
    static NSData *pw = nil;
    dispatch_once(&once, ^{
        NSString *path = [MiOSBaseDir() stringByAppendingPathComponent:@".secret"];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSData *existing = [fm fileExistsAtPath:path] ? [NSData dataWithContentsOfFile:path] : nil;
        if (existing.length >= 32) {
            pw = existing;
            return;
        }
        // Fresh material: 48 bytes of random mixed with the bundle id so a stolen file
        // alone is not enough — but no user interaction is required.
        NSMutableData *fresh = [NSMutableData dataWithLength:48];
        if (SecRandomCopyBytes(kSecRandomDefault, 48, fresh.mutableBytes) != errSecSuccess) {
            // Fallback: fill from arc4random. Still device-local, still unpredictable.
            uint8_t *b = fresh.mutableBytes;
            for (NSUInteger i = 0; i < fresh.length; i++) b[i] = (uint8_t)arc4random();
        }
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"com.burbn.instagram";
        NSData *bidData = [bid dataUsingEncoding:NSUTF8StringEncoding];
        uint8_t *b = fresh.mutableBytes;
        for (NSUInteger i = 0; i < bidData.length && i < fresh.length; i++) {
            b[i] ^= ((const uint8_t *)bidData.bytes)[i];
        }
        [fresh writeToFile:path atomically:YES];
        pw = [fresh copy];
    });
    return pw;
}

#pragma mark - Primitives

static NSData *pbkdf2(NSData *password, NSData *salt, NSUInteger len) {
    NSMutableData *out = [NSMutableData dataWithLength:len];
    CCKeyDerivationPBKDF(kCCPBKDF2,
                         password.bytes, password.length,
                         salt.bytes, salt.length,
                         kCCPRFHmacAlgSHA256, kMiOSPBKDFRounds,
                         out.mutableBytes, len);
    return out;
}

static NSData *hmacSHA256(NSData *key, NSData *data) {
    uint8_t mac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, data.bytes, data.length, mac);
    return [NSData dataWithBytes:mac length:CC_SHA256_DIGEST_LENGTH];
}

// Constant-time compare (matches Blaze's BLCryptor_ConstantCompare).
static BOOL ctEqual(const void *a, const void *b, size_t n) {
    const uint8_t *x = a; const uint8_t *y = b; uint8_t r = 0;
    for (size_t i = 0; i < n; i++) r |= (uint8_t)(x[i] ^ y[i]);
    return r == 0;
}

static NSData *aes256cbc(NSData *key, NSData *iv, NSData *input, CCOperation op) {
    size_t outLen = input.length + kCCBlockSizeAES128;
    NSMutableData *out = [NSMutableData dataWithLength:outLen];
    size_t moved = 0;
    CCCryptorStatus rv = CCCrypt(op, kCCAlgorithmAES, kCCOptionPKCS7Padding,
                                 key.bytes, key.length,
                                 iv.bytes,
                                 input.bytes, input.length,
                                 out.mutableBytes, outLen, &moved);
    if (rv != kCCSuccess) return nil;
    out.length = moved;
    return out;
}

#pragma mark - Public

+ (NSData *)encrypt:(NSData *)plaintext {
    if (plaintext == nil) return nil;

    NSMutableData *encSalt  = [NSMutableData dataWithLength:kSaltLen];
    NSMutableData *hmacSalt = [NSMutableData dataWithLength:kSaltLen];
    NSMutableData *iv       = [NSMutableData dataWithLength:kIVLen];
    if (SecRandomCopyBytes(kSecRandomDefault, kSaltLen, encSalt.mutableBytes)  != errSecSuccess ||
        SecRandomCopyBytes(kSecRandomDefault, kSaltLen, hmacSalt.mutableBytes) != errSecSuccess ||
        SecRandomCopyBytes(kSecRandomDefault, kIVLen,   iv.mutableBytes)       != errSecSuccess) {
        return nil;
    }

    NSData *password = [self devicePassword];
    NSData *encKey   = pbkdf2(password, encSalt, kKeyLen);
    NSData *hmacKey  = pbkdf2(password, hmacSalt, kKeyLen);

    NSData *cipher = aes256cbc(encKey, iv, plaintext, kCCEncrypt);
    if (!cipher) return nil;

    NSMutableData *out = [NSMutableData dataWithCapacity:kHeaderLen + cipher.length + kHMACLen];
    [out appendBytes:&kMiOSCryptVersion length:1];
    [out appendData:encSalt];
    [out appendData:hmacSalt];
    [out appendData:iv];
    [out appendData:cipher];
    NSData *mac = hmacSHA256(hmacKey, out);
    [out appendData:mac];
    return out;
}

+ (NSData *)decrypt:(NSData *)blob {
    if (blob.length < kHeaderLen + kHMACLen) return nil;
    const uint8_t *b = blob.bytes;
    if (b[0] != kMiOSCryptVersion) return nil;

    NSData *encSalt  = [NSData dataWithBytes:b + 1              length:kSaltLen];
    NSData *hmacSalt = [NSData dataWithBytes:b + 1 + kSaltLen   length:kSaltLen];
    NSData *iv       = [NSData dataWithBytes:b + 1 + 2*kSaltLen length:kIVLen];
    NSUInteger cipherLen = blob.length - kHeaderLen - kHMACLen;
    NSData *cipher   = [NSData dataWithBytes:b + kHeaderLen length:cipherLen];
    NSData *mac      = [NSData dataWithBytes:b + blob.length - kHMACLen length:kHMACLen];

    NSData *password = [self devicePassword];
    NSData *hmacKey  = pbkdf2(password, hmacSalt, kKeyLen);
    NSData *expected = hmacSHA256(hmacKey, [blob subdataWithRange:NSMakeRange(0, blob.length - kHMACLen)]);
    if (expected.length != mac.length || !ctEqual(expected.bytes, mac.bytes, mac.length)) {
        return nil;
    }

    NSData *encKey = pbkdf2(password, encSalt, kKeyLen);
    return aes256cbc(encKey, iv, cipher, kCCDecrypt);
}

@end
