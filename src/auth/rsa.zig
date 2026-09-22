//! RSA signing for service account keys: RSASSA-PKCS1-v1_5 over SHA-256,
//! the one scheme Google's token endpoint accepts for a service account's
//! JWT assertion. Parses the PEM private key a key file carries, PKCS#8
//! (`PRIVATE KEY`) or PKCS#1 (`RSA PRIVATE KEY`), without allocating: the
//! decoded key lives on the stack and is wiped.
//!
//! The modular exponentiation is `std.crypto.ff`, whose secret-exponent
//! path is constant-time. Every signature is checked against the public
//! exponent before it is returned, so a corrupted key fails here, loudly,
//! instead of at the server.

const std = @import("std");
const ff = std.crypto.ff;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// Google issues 2048-bit service account keys and accepts uploaded keys
/// up to 4096 bits.
pub const max_modulus_bits = 4096;
/// Uploaded keys may be as small as 1024 bits; Google no longer issues them.
pub const min_modulus_bits = 1024;
pub const max_modulus_bytes = max_modulus_bits / 8;

const Modulus = ff.Modulus(max_modulus_bits);
const Fe = Modulus.Fe;

pub const ParseError = error{
    /// Not a PEM private key, or one whose contents do not decode.
    InvalidPrivateKey,
    /// A well-formed key this code cannot use: encrypted, not RSA,
    /// multi-prime, or outside the supported modulus sizes.
    UnsupportedKey,
};

pub const SignError = error{
    /// The signature did not verify against the key's own public exponent:
    /// the key is corrupt, or its parts do not belong together.
    SignatureFailed,
};

pub const PrivateKey = struct {
    n: Modulus,
    e: Fe,
    /// The private exponent, big-endian. Secret: `deinit` wipes it.
    d: [max_modulus_bytes]u8,
    d_len: usize,
    /// The modulus in bytes, which is also every signature's length.
    len: usize,

    pub fn deinit(key: *PrivateKey) void {
        std.crypto.secureZero(u8, &key.d);
        key.* = undefined;
    }

    /// Signs `msg` with RSASSA-PKCS1-v1_5 and SHA-256. Writes `key.len`
    /// bytes into `out` and returns them.
    pub fn sign(key: *const PrivateKey, msg: []const u8, out: []u8) SignError![]const u8 {
        const k = key.len;
        std.debug.assert(out.len >= k);
        var em_buf: [max_modulus_bytes]u8 = undefined;
        const em = encodeMessage(msg, em_buf[0..k]);
        // EM starts 0x00 0x01, so it is always below the modulus.
        const m = Fe.fromBytes(key.n, em, .big) catch return error.SignatureFailed;
        const s = key.n.powWithEncodedExponent(m, key.d[0..key.d_len], .big) catch return error.SignatureFailed;
        s.toBytes(out[0..k], .big) catch return error.SignatureFailed;
        const check = key.n.powPublic(s, key.e) catch return error.SignatureFailed;
        if (!check.eql(m)) return error.SignatureFailed;
        return out[0..k];
    }
};

/// Parses a PEM private key. `pem` may hold anything; nothing secret from
/// it outlives the call except inside the returned key.
pub fn parsePem(pem: []const u8) ParseError!PrivateKey {
    if (std.mem.indexOf(u8, pem, "-----BEGIN ENCRYPTED PRIVATE KEY-----") != null) {
        return error.UnsupportedKey;
    }
    const body = pemBody(pem, "PRIVATE KEY") orelse
        pemBody(pem, "RSA PRIVATE KEY") orelse
        return error.InvalidPrivateKey;
    // A 4096-bit PKCS#8 key is about 2.4 KiB of DER.
    var der_buf: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &der_buf);
    const decoder = std.base64.standard.decoderWithIgnore(" \t\r\n");
    const len = decoder.decode(&der_buf, body) catch return error.InvalidPrivateKey;
    return parseDer(der_buf[0..len]);
}

/// The base64 between `-----BEGIN <label>-----` and `-----END <label>-----`.
fn pemBody(pem: []const u8, comptime label: []const u8) ?[]const u8 {
    const begin = "-----BEGIN " ++ label ++ "-----";
    const end = "-----END " ++ label ++ "-----";
    const start = std.mem.indexOf(u8, pem, begin) orelse return null;
    const after = start + begin.len;
    const stop = std.mem.indexOfPos(u8, pem, after, end) orelse return null;
    return pem[after..stop];
}

/// One DER element at `pos`, which moves past it. Null when the bytes do
/// not hold one; nothing here trusts the input.
const Element = struct { tag: u8, body: []const u8 };

fn readElement(bytes: []const u8, pos: *usize) ?Element {
    var i = pos.*;
    if (bytes.len - i < 2) return null;
    const tag = bytes[i];
    var len: usize = bytes[i + 1];
    i += 2;
    if (len >= 0x80) {
        const n = len - 0x80;
        if (n == 0 or n > 4 or bytes.len - i < n) return null;
        len = 0;
        for (bytes[i..][0..n]) |b| len = (len << 8) | b;
        i += n;
    }
    if (bytes.len - i < len) return null;
    pos.* = i + len;
    return .{ .tag = tag, .body = bytes[i..][0..len] };
}

/// A DER INTEGER's magnitude: positive, sign padding stripped.
fn magnitude(int: Element) ?[]const u8 {
    if (int.tag != 0x02 or int.body.len == 0) return null;
    if (int.body[0] & 0x80 != 0) return null;
    var b = int.body;
    while (b.len > 0 and b[0] == 0) b = b[1..];
    return b;
}

const rsa_oid = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01 };

fn parseDer(bytes: []const u8) ParseError!PrivateKey {
    var pos: usize = 0;
    const outer = readElement(bytes, &pos) orelse return error.InvalidPrivateKey;
    if (outer.tag != 0x30) return error.InvalidPrivateKey;
    var p: usize = 0;
    const version = readElement(outer.body, &p) orelse return error.InvalidPrivateKey;
    if (version.tag != 0x02) return error.InvalidPrivateKey;
    const second = readElement(outer.body, &p) orelse return error.InvalidPrivateKey;
    // A bare RSAPrivateKey starts INTEGER, INTEGER: hand the whole thing over.
    if (second.tag == 0x02) return parsePkcs1(bytes);
    // PKCS#8: version 0, an AlgorithmIdentifier naming RSA, then the
    // RSAPrivateKey in an OCTET STRING.
    if (second.tag != 0x30) return error.InvalidPrivateKey;
    if (!std.mem.eql(u8, version.body, &.{0})) return error.UnsupportedKey;
    var a: usize = 0;
    const oid = readElement(second.body, &a) orelse return error.InvalidPrivateKey;
    if (oid.tag != 0x06) return error.InvalidPrivateKey;
    if (!std.mem.eql(u8, oid.body, &rsa_oid)) return error.UnsupportedKey;
    const inner = readElement(outer.body, &p) orelse return error.InvalidPrivateKey;
    if (inner.tag != 0x04) return error.InvalidPrivateKey;
    return parsePkcs1(inner.body);
}

/// RFC 8017 A.1.2: SEQUENCE { version, n, e, d, p, q, dP, dQ, qInv }. Only
/// n, e and d are used; signing with d alone is simpler than CRT and fast
/// enough for a token an hour.
fn parsePkcs1(bytes: []const u8) ParseError!PrivateKey {
    var pos: usize = 0;
    const seq = readElement(bytes, &pos) orelse return error.InvalidPrivateKey;
    if (seq.tag != 0x30) return error.InvalidPrivateKey;
    var p: usize = 0;
    const version = readElement(seq.body, &p) orelse return error.InvalidPrivateKey;
    if (version.tag != 0x02) return error.InvalidPrivateKey;
    // Version 1 is a multi-prime key, which has a different tail.
    if (!std.mem.eql(u8, version.body, &.{0})) return error.UnsupportedKey;
    const n_int = readElement(seq.body, &p) orelse return error.InvalidPrivateKey;
    const e_int = readElement(seq.body, &p) orelse return error.InvalidPrivateKey;
    const d_int = readElement(seq.body, &p) orelse return error.InvalidPrivateKey;
    const n_bytes = magnitude(n_int) orelse return error.InvalidPrivateKey;
    const e_bytes = magnitude(e_int) orelse return error.InvalidPrivateKey;
    const d_bytes = magnitude(d_int) orelse return error.InvalidPrivateKey;

    if (n_bytes.len > max_modulus_bytes) return error.UnsupportedKey;
    const n = Modulus.fromBytes(n_bytes, .big) catch return error.InvalidPrivateKey;
    if (n.bits() < min_modulus_bits) return error.UnsupportedKey;
    const e = Fe.fromBytes(n, e_bytes, .big) catch return error.InvalidPrivateKey;
    if (!e.isOdd()) return error.InvalidPrivateKey;
    if (d_bytes.len == 0 or d_bytes.len > max_modulus_bytes) return error.InvalidPrivateKey;

    var key: PrivateKey = .{
        .n = n,
        .e = e,
        .d = @splat(0),
        .d_len = d_bytes.len,
        .len = (n.bits() + 7) / 8,
    };
    @memcpy(key.d[0..d_bytes.len], d_bytes);
    return key;
}

/// RFC 8017 9.2, EMSA-PKCS1-v1_5 with SHA-256:
/// `0x00 0x01 FF..FF 0x00 DigestInfo hash`, filling `em`.
fn encodeMessage(msg: []const u8, em: []u8) []const u8 {
    // DigestInfo for SHA-256: SEQUENCE { AlgorithmIdentifier, OCTET STRING (32) }.
    const digest_info = [_]u8{
        0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01,
        0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20,
    };
    const t_len = digest_info.len + Sha256.digest_length;
    // The minimum modulus leaves far more than the 11 bytes RFC 8017 needs.
    std.debug.assert(em.len >= t_len + 11);
    em[0] = 0x00;
    em[1] = 0x01;
    const t_start = em.len - t_len;
    @memset(em[2 .. t_start - 1], 0xff);
    em[t_start - 1] = 0x00;
    @memcpy(em[t_start..][0..digest_info.len], &digest_info);
    Sha256.hash(msg, em[em.len - Sha256.digest_length ..][0..Sha256.digest_length], .{});
    return em;
}

// Test fixtures: throwaway keys generated for these tests with OpenSSL,
// shared with ServiceAccount's tests (pub, but rsa.zig is not exported).
// never used anywhere real. The signatures are OpenSSL's own
// (`openssl dgst -sha256 -sign`) over `test_message`, so these tests
// check against an independent implementation.

pub const test_message = "sign me, exactly these bytes";

/// A 1024-bit test key: the smallest accepted, and much faster to sign
/// with in Debug, so heavier test loops use it.
pub const test_key_1024 =
    \\-----BEGIN PRIVATE KEY-----
    \\MIICdQIBADANBgkqhkiG9w0BAQEFAASCAl8wggJbAgEAAoGBANec+YqTS8dG4k8D
    \\U2CiScMOaW22NEmsAD0t+UAONP1d1Vi9E8M5hKd5G8zvm1gpvDiZaAZ4OHDcYi49
    \\RHVaemHdaa5F6+KZW+wVR1FbOxV+Fbjn/L2XsMzy132RH186Ty7BKeOs42dzeiYg
    \\Gc43bzgRxfXBY61bvetGjmu3e+UJAgMBAAECgYB4s5e+y9aQKE5ojSQP5MoGN/st
    \\P+LlmzRHC4WNJmbjr7PPiYmWsIxidJnrj/cW08ZaqQZjGMn/5F/SItpAF/aJ64Ud
    \\3Mjgt76f42E+aThOhifugbtOKkeZ5lfH22ujR/hfFxDRiFdmIwG1GPJC7TEPe1fX
    \\0r9VE2BV0DMbYBaxAQJBAPM4pvJNy+/0cZRKsHL62eHl6bZMt7fMsmmJmkkrzACf
    \\q5aHeeYX1nqy5aUR4cMl9j5pkqGvI0KomYI4bDiOEHUCQQDi8P22Q5ADupmjehqj
    \\UdGPFE/2yFyx2nkc/2of9V7WzJorTg/Wz0LcJIeinP9Tb1naraRcnO2N00YKYt40
    \\HO/FAkBZ9p2ByJbjhcYxNMM5dGH9NZ6R6KSX3qYrdVNVN1b48BZ20lubaTvTHLLm
    \\sMuR9Eu14DT1iyN+t4A4c4hMDvg1AkBBgltaj6o0yVqsTAUAfA/IA48Jp9DKLkyj
    \\yD70NrpHuwwN0BzWX0Hnlkvo7vTtOslvTIyTh2EzfXdMbDnERU4ZAkAcqPdLpGOv
    \\rM6tCpzaY2n/6xJfE+siX/07sx+RJ683XHciy2puPXwgRdJ9oaNPGYbyAFaagTSR
    \\YAS7APpRBYGA
    \\-----END PRIVATE KEY-----
;

pub const test_sig_1024_hex = "58b79695ef8b5af573d01eb3ab4694c8c75744f1b624d49b0726346d11b08aa2" ++
    "4260ec91ace15c7b3fedeed9c83167d6dd9eddec082ae6724e1ea73d157be4be" ++
    "45a85b007cceed1e05fd7d446dc52feecb1bbc765c559eba408cb6653814cba0" ++
    "2d555263fe4a83a9a3935f397738e96280eccec1762f5b8a98eb915f72fa5003";

/// A 2048-bit test key, PKCS#8.
pub const test_key_2048 =
    \\-----BEGIN PRIVATE KEY-----
    \\MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCJzXN/oMxw5dqm
    \\rwhvYOrg65GgRHWQ3u713WfNhiD96QUDS134zSOkgh1pAPLkb+n9Ju12sm+MDeL4
    \\mjYfpQWZ66jfz311r83gnWSCTL3F2Yh6NxNa4flbjPje+TGxdYtfM+Thu0GDZa1q
    \\iDXwoNDPUp1518fS7oQV/6mu2Bp6u2OyLXjb7hEsO0lxrNdrC20pOQZPgQHih7pn
    \\KJUkhMyktjgniWfI4HLOidUspi4Tu7RV+buuS8sPKmHfCzXZhxxRLCaUH17z6KID
    \\B7XDn195tZ9zIUP7oJBhb+8PMCcSosyZrEhspN0mMzC9pGS0GGxSlk98YYJJ/S66
    \\hGTuomx9AgMBAAECggEAEmVwDtC7mjLFPs1NFfldQcuQ9FFPVJi+U+pLyj8mtl7e
    \\QXNVRzqzkGmiXXs38dES7q28s8TcaVkNPNzxbsYL+mFgeQhtGkHu/RZl7ZMrHneM
    \\5avmlJJoRJWMP9AKl0M26O23l371HwJ65Sbr9ISze4nu5e4tifY3gexQjbvhxRJ+
    \\9V5piS6uCPzJOD30d7zsDcsF901Zh9akClBYRdqkkX8HoWa/lP3v5IqhXy4j3KxL
    \\oWWNj4fuj6fJ2vhgE9wKgfePwB7ggQdcyaMyw2rZ+jOtwSQWj87PMkYfDBEk4BnR
    \\k/n1r19ygtcNebncGcvJavvQyL1GzRiMpoR5Mkp2zQKBgQC9LqToiRoiB1kwSZnB
    \\3RJZCdkLJcgcPRi0rGNg0qQOI9pCMo+REPwedIuOMtSDKE/7X5cClO6FWckrKic7
    \\gstm05RpKtko5GujVUeCTKuTVHAkhsDgatSMaO8HdtWjQnSBTCiUAJHClxH43f2j
    \\pnqJHzQQrbIslgXHAsiYcr+j3wKBgQC6eTGTO3FC7TSqUSayfNCeEJibcUFBfUiE
    \\5aAsNXfrtOzmHUkqFsw45CVfLgi0lL8ioY3asAqb1Y5ZAcfE9fcgUgWXjrWWawTb
    \\TYNxzP1LqUaI6kY9HtEE2JmtzNde/xCppQRQhGLfCOy3OMTeQ+XzJ4bE69OaGmWq
    \\hHcw+KmbIwKBgGot9tKouKkmtLE8bfb4DGc69r2h+/mVdPta0gAy2W8yQjrrQ9bo
    \\0IiLYxRxhQMEKjftA8WoL2Na7GS0qQZmt6DD2cVZDj88TQmEQLlqLNZpCvQFSdXr
    \\P9Z6wsXOtcOG9frn8tJ2q1irD6Q9fDFQq++wOrmts5YAscdr0Yh2xwbDAoGAM3Xa
    \\ro0K9rNLg20dxsgXMmfWFZ+tqIsQhkxwZYLj81Jcxixy0oC0H0cm4RttH5ilHsOC
    \\yEUoyFSpEfshzEMszeiUznx9tGMYVgUQL0mo5UZzxrkQZTGp8TJtRr9u+DJfwNFf
    \\XXELcA2gdfferJAEV5Qi5xlFrhN21xXzZrpY5A0CgYEAllY2eCgSRj9d0SiPYHtP
    \\Y0XysnibDArafqRUMK/bcodMqnD8PpZD/qowl2OAz18BCewZk9GX3deAd4jdGFCH
    \\1CH5qT8s2fqMVABffzxKMtHqNTWwXJroDHAZqqmxKdZ8p9ItQvl6jPR34EKkXgR4
    \\og3ZEBNlBXBeVBFa7gmViI8=
    \\-----END PRIVATE KEY-----
;

/// The same 2048-bit key, PKCS#1.
const test_key_2048_pkcs1 =
    \\-----BEGIN RSA PRIVATE KEY-----
    \\MIIEowIBAAKCAQEAic1zf6DMcOXapq8Ib2Dq4OuRoER1kN7u9d1nzYYg/ekFA0td
    \\+M0jpIIdaQDy5G/p/SbtdrJvjA3i+Jo2H6UFmeuo3899da/N4J1kgky9xdmIejcT
    \\WuH5W4z43vkxsXWLXzPk4btBg2Wtaog18KDQz1KdedfH0u6EFf+prtgaertjsi14
    \\2+4RLDtJcazXawttKTkGT4EB4oe6ZyiVJITMpLY4J4lnyOByzonVLKYuE7u0Vfm7
    \\rkvLDyph3ws12YccUSwmlB9e8+iiAwe1w59febWfcyFD+6CQYW/vDzAnEqLMmaxI
    \\bKTdJjMwvaRktBhsUpZPfGGCSf0uuoRk7qJsfQIDAQABAoIBABJlcA7Qu5oyxT7N
    \\TRX5XUHLkPRRT1SYvlPqS8o/JrZe3kFzVUc6s5Bpol17N/HREu6tvLPE3GlZDTzc
    \\8W7GC/phYHkIbRpB7v0WZe2TKx53jOWr5pSSaESVjD/QCpdDNujtt5d+9R8CeuUm
    \\6/SEs3uJ7uXuLYn2N4HsUI274cUSfvVeaYkurgj8yTg99He87A3LBfdNWYfWpApQ
    \\WEXapJF/B6Fmv5T97+SKoV8uI9ysS6FljY+H7o+nydr4YBPcCoH3j8Ae4IEHXMmj
    \\MsNq2fozrcEkFo/OzzJGHwwRJOAZ0ZP59a9fcoLXDXm53BnLyWr70Mi9Rs0YjKaE
    \\eTJKds0CgYEAvS6k6IkaIgdZMEmZwd0SWQnZCyXIHD0YtKxjYNKkDiPaQjKPkRD8
    \\HnSLjjLUgyhP+1+XApTuhVnJKyonO4LLZtOUaSrZKORro1VHgkyrk1RwJIbA4GrU
    \\jGjvB3bVo0J0gUwolACRwpcR+N39o6Z6iR80EK2yLJYFxwLImHK/o98CgYEAunkx
    \\kztxQu00qlEmsnzQnhCYm3FBQX1IhOWgLDV367Ts5h1JKhbMOOQlXy4ItJS/IqGN
    \\2rAKm9WOWQHHxPX3IFIFl461lmsE202Dccz9S6lGiOpGPR7RBNiZrczXXv8QqaUE
    \\UIRi3wjstzjE3kPl8yeGxOvTmhplqoR3MPipmyMCgYBqLfbSqLipJrSxPG32+Axn
    \\Ova9ofv5lXT7WtIAMtlvMkI660PW6NCIi2MUcYUDBCo37QPFqC9jWuxktKkGZreg
    \\w9nFWQ4/PE0JhEC5aizWaQr0BUnV6z/WesLFzrXDhvX65/LSdqtYqw+kPXwxUKvv
    \\sDq5rbOWALHHa9GIdscGwwKBgDN12q6NCvazS4NtHcbIFzJn1hWfraiLEIZMcGWC
    \\4/NSXMYsctKAtB9HJuEbbR+YpR7DgshFKMhUqRH7IcxDLM3olM58fbRjGFYFEC9J
    \\qOVGc8a5EGUxqfEybUa/bvgyX8DRX11xC3ANoHX33qyQBFeUIucZRa4TdtcV82a6
    \\WOQNAoGBAJZWNngoEkY/XdEoj2B7T2NF8rJ4mwwK2n6kVDCv23KHTKpw/D6WQ/6q
    \\MJdjgM9fAQnsGZPRl93XgHeI3RhQh9Qh+ak/LNn6jFQAX388SjLR6jU1sFya6Axw
    \\GaqpsSnWfKfSLUL5eoz0d+BCpF4EeKIN2RATZQVwXlQRWu4JlYiP
    \\-----END RSA PRIVATE KEY-----
;

/// A 4096-bit test key, PKCS#8.
const test_key_4096 =
    \\-----BEGIN PRIVATE KEY-----
    \\MIIJQgIBADANBgkqhkiG9w0BAQEFAASCCSwwggkoAgEAAoICAQDLuSitBViDHeRY
    \\WSBxNn2BvRqGwW9RCB7NTFd5yhxnDouEPREdp3o3hZ5IvXd86qAMyQkBp1qemTSw
    \\f2zsZ7MVNkrR0zxQtSs7vwp+OK1nK1im5oUqvqEuzGESt045zWUONE6Ryhc9RR78
    \\ZUfCYtxH33tOK//2tjjQaEPLiuYeA6GshGfNevtGRRbnro/7d7U5n6UYENgUkIA9
    \\ZiZpEj628Gi7QkJEKtbeaPeJAOzXxS3Mtv9k8Pddur0JnBr+q3nJMUSo15xYmxoY
    \\HbS4HHrmMpryxy3VICiDdiIDnjDn+pt1v9SXJAAANQ+apAguQE6ZIaC+HiWBSPtR
    \\TvsmoQz/mmsQUWvJSU2Bu5qSvgUhAumJ4iWyW9GpKr1ys4eAF8Gs4L1eAw8KRUK4
    \\m1Yxi6ONBaVeZLE9fgqkve9QJDASjOh1aTAvc+HXLzSCUBlJPfwCsWadRqvumhhn
    \\OQTh2JcK655AV6yekZ0FXefUoOahMVnJHohfW+waWrmtgNiZWUkGO1smgGIg0oVk
    \\6vSqN9OOdPhEefXYFZFq2udg4WXkLg+BtGbsXBAIcc3JSjNIFHX0ReyTNtdRbqXD
    \\uqqu9DMgOvj8p5jYHCXhNB232eRFIq4nWYcYpeQel89vAf1PMXHe9dokhEw7PCmN
    \\8SwX5xymoP1E97UnS/nNVM+vHJa00QIDAQABAoIB/zx/XOCQR0oc7aEJBSrIIM6x
    \\6u6w1DUHrnsOqtQ0Tel7Sy1ROvhTbH2ntjDAzTUuMdk9CIzAzq4nf4PqU1E97qTM
    \\gHcgd/GW8qKuWMai6zi9z0oeB78j//O9Dy352K+jDwguoz2ztFXsH2SaOqOn2uVl
    \\z494u7MN0q5uGYVShclvnBkZT//d6G81rG7meUQuK0Al0ThaJUU76fCAU8TUZjQQ
    \\PCECtOU36tEtCT39a0C/dg631OXCBj8PUmVIKqTHgXRyG5pOD+tur3nLWIglj+U1
    \\Fk6CV5/KCg9dFt+qt4nPCsQs3AZL6oWZmVRNEGarvcLHVswHM2180DxPPd01AfJF
    \\69pXxIJjS+hSAg4u6+iwCapCxLS5RydIuocGa44hXkVMeKsfhGqtD0v3Pbjd9l85
    \\7YUWItqEeFVH75vcNzlBC4mDPx2CjVp9M6ccvaxVfTcn2e2gDuacHmSViQI02p53
    \\Xe97RIJ9PkXiMMBIyWaCraUSM6mxQSm0TbBs7PSGJoeEZsDkbNd4Kj9D8qV/GRmK
    \\i5crPGa0Bo303kmvCvbroL4rFbEoEbPOsZSAV/+KYT0C2V+u1mrjtHkMseUeaT8X
    \\SD9MiOYQuyoBXjyrWIPIyAuq3lqVaV2ZI/OHRFG3+or+6MUnEcPsGAwrpYna6q57
    \\TsGaSjRiVfid/lfLm3ECggEBAP/X0H1i+ufQ1MzBX3YbubaCqi6Kk7EcY57xYoqf
    \\eDX+I9RGZmLTPu0VHRBeGYuf9hzmX4qVCvVfVWEGNjhPerjT6hXgMWB2gaBersjq
    \\VMZFtJ7A9jcUdPr/36vGNiRyms28oMljhlPH/JENAAinEZ6hylDnfI+7o79DMFrc
    \\zvUb4X3Hh4yiv6W2lSz8iCX9403VMCmEPxOgcwPj53Kog9+u1Vb2YDil7xIWWC26
    \\Tqhmza51PolGJcrqr/XNj75HNGhGpBNHtr6i/niid5XIJTtk860FFt8nE6QXa2Y5
    \\RJiuCPenteLr58PTo8elsA4K/G97Cz109/hcb1HBBtTTknkCggEBAMvZKHA2nGrd
    \\kMIhyd06I/cYT+MgeWJJUNEmUR+EMTE7fQGzTwN7kId6TtkiUaWybQXj5Z/0wXAV
    \\gQdcHg05UUp9LYg8Wh9A76GhE8CiZiwC0ud84nPRZhNb3lhMDsOujc3gRTj1A+/9
    \\LDCzChliOFIXD6RvWNw7qkCAuGDo1G7+gjvbuJivXKHNi/BvqrbHpSx3DQLjjDO0
    \\QIdzTo1jGskhSma+sqnYA+bDYIks04ux6fZ0RkIrbU4PueeoHmJGOURAF7Z+190J
    \\MTkxHgG1GswJt6JjebXF3J37gHnki4aKx8R/5+DnEcHSOmVU39gl+at18ch7w3FT
    \\dx6mtTyG3xkCggEAPEFM1isYor45UBv+6qcu/wAZKqryi9T+1XFOXw2d10GKmLUX
    \\6hCMknPVi4ROCedbpITRXacqlI2mYxp+bJazdZJbYFmT538hmm6SRbmCy8ug9X7G
    \\vkQwJOlceW1OVRk0wl25lJS/Dz5biqIALwmCCdVa++D5IjT0JNijK9MzXuD5I5F5
    \\qDKwZkvxKE41lpUMEsmx9SUzYeD5FaJ4YTW1EVpw3nFaSh0yiBUBIYvueJT1vi/Y
    \\0aXWwsqxNHf8cbj9a82vWOcb8BwdSLYi6gDgW/OzvD0lnNrsMkpdvg6gzEC41fMG
    \\0HH0/Nb8jMnGBBisSWk2RXwl5rWGdj+65ycJKQKCAQEAmmhxkx4quV//SK2jZKmn
    \\mIGX8akliOeUCfkGNeNCB9LRy7nwveiY/6YLl7nBMsvGfVG1G8afx7DiPZrvQIEM
    \\LGpJVQqyET50xW9nsODSl7/D1YjpV2Vj9oH+F8/01xCfZTTd+ljNlLmnAXR8z+Fw
    \\W+4P8TROkPO48IcQIof6ceDi8UhruWwLtJwnxgYvv6fWW6oJ9wg5qOh+gJs9Ayfw
    \\oC1RWCZW2wQ/YEraEs4bp5Mqb35/wZt3fku3O9xCt5oNwr7xt1C5XjqaSIIGArEW
    \\DTvHF4BWLvQjOp/JH4uYjF8PFq70C428C56ckSkLLYUGa3Q5ouzsjCj28AbC/YgD
    \\8QKCAQEApN9usJ0+7OvFGEyOAoY6Ixm9z8LJ45u0UZVCXKAyJrQjObBSrauPcLX0
    \\imfZEjrAYtYz+eNKslHzHFtPdK4B9/xlNhM1iP889OpvSmbdPVkQRGNqsoPVkkaD
    \\/LVByYw0AOde57cZeqs1lQrWTgy0uLeV52EMiqOu+68UyC34wo4+OeIwxaDbsSuW
    \\woUG5t+CUkzyzeN/NWYE6VUKaJ1iDbNiu9nGFr55VFDgNgeq65uH0vJPG7Zs7O3O
    \\1xmASEn1wShuiO/uHqTmb08Vc00INY+YVFsMphEirJ7QGx2bpD+QfLzCms3PNMJI
    \\cSgHVm5Wxx/RL/00MT49ePkNID1/ag==
    \\-----END PRIVATE KEY-----
;

/// An EC P-256 key: valid PKCS#8, not RSA.
pub const test_key_ec =
    \\-----BEGIN PRIVATE KEY-----
    \\MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgAH863KtFBkbQuIiU
    \\wl14N5JJM1Bmu4BA3k2kWi2IZxyhRANCAARIkfe3Eis5p1QObAPwBkQV53XGX2hC
    \\0g/IVqDvDsoqiiN9UZd5PAogT5q1s2pzyi+q3vWt7p4/rIXodkVkXZJV
    \\-----END PRIVATE KEY-----
;

const test_sig_2048_hex = "851f9524baa1ab8010ffad57593e795a6aaded58751fee5fe7d723325d8b7846" ++
    "00b0fb548874cd3ffc0f398a64db35e1b91a009f3d0c1b027e82f9026a3a210e" ++
    "b0430384f311da1e69c4706f39b857fa77c4a765b5b60fa1af916317509dd4e9" ++
    "cda66e4e16a24c55ad2bac5814e8a5270820823580e23f204d56302325eaf6a3" ++
    "e5ef7c005ae561ec27c5013b402c41c93772bc1da678ef9d01adcb57a613c74b" ++
    "0559af290a8feec22b0a10594bde673c7691ee867c66710f7b5ed77decc8407e" ++
    "a45bfd1d3b7178acfed1e25631def0b463f23c9e6827552c0da08d422dc0890f" ++
    "f09dd7689a2bbdf2f5886a536998f14ceea8509754bd702c172b36d99276de47";

const test_sig_4096_hex = "0656f181b3b47c0e388acee7d2adf2d997cbbf7dd15d64d8e0f85552f89b17e9" ++
    "4398a875d3fa9284bb1cc5d9b584dd7e9116d9d839c79466b350501010c9aa70" ++
    "f0e0741857865dc7055dbbaba411dafaca5d34d81687a1a7280a2d59c88345cb" ++
    "406513edfdb3d85f2a58e22a3b2d199a2e0cb4572843cbdcab7fb573ce85caa5" ++
    "bfce39cd6294ed60ca8a24fdc414a692d25d0f943a92e0e0def5531cbc983635" ++
    "5f76ba88fd65bc9cf1f6fd7a0f4db568a68820c5290bf84e09e95ad815689424" ++
    "5ff51f4910759fea26c9c18319d8c64989f8fcd5f31377d8f79a128040317572" ++
    "98a152e91c7e5b2969616b4e5cce87b22e24c3d0fd578613fb81b3cbce2a29e8" ++
    "74abf4d71e74809542b7bb141a878487e82e8a81c142df0eb5b43272adb48419" ++
    "84e97afe4c0cc832468bcabcdd79357f95ae2e3c7c283f79243be78c26d7c7a8" ++
    "9381d68b99d0f027e5bab273109bb6480777c7940a6623486c6843437d045b4e" ++
    "229979181fe7bd8390d65f026566d77f012a4b26996e52f46d18807e949f0874" ++
    "7bba11d293f8b3e782f50e3f084d35be7eeb6b9dbc3d89e3629b9b27cf04c4a7" ++
    "4644a909764c19642e1db03943e53f9d15656c1bde04d7d424b8409c425b303d" ++
    "6bb333f411adc0e4da4c7198b6cc342282591cb9cf92723921a3ee70eefb23fe" ++
    "82e98f9b0a77da7662523824d71f39ed872726eb1a7aaa0220a85bec72238d44";

const testing = std.testing;
const test_util = @import("core").testing;

fn expectSignature(pem: []const u8, expected_hex: []const u8) !void {
    var key = try parsePem(pem);
    defer key.deinit();
    var expected: [max_modulus_bytes]u8 = undefined;
    const want = try std.fmt.hexToBytes(&expected, expected_hex);
    try testing.expectEqual(want.len, key.len);
    var out: [max_modulus_bytes]u8 = undefined;
    const got = try key.sign(test_message, &out);
    try testing.expectEqualSlices(u8, want, got);
}

test "rsa: a 1024-bit key signs exactly as OpenSSL does" {
    try expectSignature(test_key_1024, test_sig_1024_hex);
}

test "rsa: a 2048-bit PKCS#8 key signs exactly as OpenSSL does" {
    try expectSignature(test_key_2048, test_sig_2048_hex);
}

test "rsa: the same key as PKCS#1 gives the same signature" {
    try expectSignature(test_key_2048_pkcs1, test_sig_2048_hex);
}

test "rsa: a 4096-bit key signs exactly as OpenSSL does" {
    try expectSignature(test_key_4096, test_sig_4096_hex);
}

test "rsa: signing is deterministic, and messages differ" {
    var key = try parsePem(test_key_2048);
    defer key.deinit();
    var a: [max_modulus_bytes]u8 = undefined;
    var b: [max_modulus_bytes]u8 = undefined;
    try testing.expectEqualSlices(u8, try key.sign("m", &a), try key.sign("m", &b));
    try testing.expect(!std.mem.eql(u8, try key.sign("m", &a), try key.sign("n", &b)));
}

test "rsa: what cannot be a usable key is refused by kind" {
    // Not PEM at all, or PEM whose contents are not a key.
    try testing.expectError(error.InvalidPrivateKey, parsePem(""));
    try testing.expectError(error.InvalidPrivateKey, parsePem("not a key"));
    try testing.expectError(error.InvalidPrivateKey, parsePem("-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----"));
    try testing.expectError(error.InvalidPrivateKey, parsePem("-----BEGIN PRIVATE KEY-----\nnot base64!\n-----END PRIVATE KEY-----"));
    try testing.expectError(error.InvalidPrivateKey, parsePem("-----BEGIN PRIVATE KEY-----"));
    // A key that is whole but not one this code can use.
    try testing.expectError(error.UnsupportedKey, parsePem(test_key_ec));
    try testing.expectError(error.UnsupportedKey, parsePem("-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAAA\n-----END ENCRYPTED PRIVATE KEY-----"));
    // Truncated: the start of a real key, cut mid-structure.
    var cut: [200]u8 = undefined;
    @memcpy(&cut, test_key_2048[0..200]);
    try testing.expectError(error.InvalidPrivateKey, parsePem(cut ++ "\n-----END PRIVATE KEY-----"));
}

fn pemProperty(_: void, input: []const u8) !void {
    // Arbitrary bytes: a key or an error, never a crash.
    var key = parsePem(input) catch return;
    key.deinit();
}

fn wrappedProperty(_: void, input: []const u8) !void {
    // Valid PEM armor around arbitrary base64, so the DER parser gets fed.
    var b64_buf: [512]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&b64_buf, input[0..@min(input.len, 384)]);
    var pem_buf: [1024]u8 = undefined;
    const pem = std.fmt.bufPrint(&pem_buf, "-----BEGIN PRIVATE KEY-----\n{s}\n-----END PRIVATE KEY-----", .{encoded}) catch unreachable;
    var key = parsePem(pem) catch return;
    key.deinit();
}

test "fuzz rsa: arbitrary PEM input never crashes" {
    try test_util.fuzzBytes({}, pemProperty, .{ .corpus = &.{
        test_key_2048[0..64],
        "-----BEGIN RSA PRIVATE KEY-----\nMA==\n-----END RSA PRIVATE KEY-----",
        "-----BEGIN PRIVATE KEY-----\n\n-----END PRIVATE KEY-----",
    } });
}

test "fuzz rsa: arbitrary DER inside valid armor never crashes" {
    try test_util.fuzzBytes({}, wrappedProperty, .{ .corpus = &.{
        "\x30\x82\x04\xa3\x02\x01\x00",
        "\x30\x03\x02\x01\x00",
        "\x30\x84\xff\xff\xff\xff",
        "\x02\x00",
    } });
}
