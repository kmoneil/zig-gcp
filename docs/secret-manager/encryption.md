[Docs](../README.md) › [Secret Manager](README.md) › Encryption keys

# 🔐 Customer-managed encryption keys

Secret Manager encrypts every version under Google's keys. A secret can
name Cloud KMS keys instead: each version's data key is then wrapped by
the key's primary version, and the version records which key version
that was. The library names keys; it does not make them.

**On this page:** [Where the key goes](#where-the-key-goes) ·
[Granting the key](#granting-the-key) ·
[Changing keys](#changing-keys) ·
[When a key goes away](#when-a-key-goes-away)

## Where the key goes

| Secret | Field | The key's location |
| --- | --- | --- |
| Global, automatic replication | `SecretConfig.kms_key` | `global` |
| Global, user-managed replication | `Replica.kms_key`, on each replica | the replica's own; every replica has a key, or none does |
| Regional | `SecretConfig.kms_key` | the client's location |

```zig
var created = try secrets.secret("db-password").create(.{
    .replication = .{ .user_managed = &.{
        .{ .location = "us-east1", .kms_key = "projects/my-project/locations/us-east1/keyRings/app/cryptoKeys/secrets" },
        .{ .location = "us-central1", .kms_key = "projects/my-project/locations/us-central1/keyRings/app/cryptoKeys/secrets" },
    } },
});
defer created.deinit();
```

A key named in full, in the wrong location, or beside replicas with
none, is refused before sending, `error.InvalidArgument`, as production
refuses each with a rule of its own. `SecretInfo` reads the keys back:
`kms_key` for an automatic or regional secret, `replicas` for a
user-managed one. `VersionInfo.kms_key_versions` names the key version
that wrapped each version, per replica:
`projects/P/locations/L/keyRings/R/cryptoKeys/K/cryptoKeyVersions/N`.

## Granting the key

Secret Manager's service agent uses the key, so it needs
`roles/cloudkms.cryptoKeyEncrypterDecrypter` on it before a secret names
it; `client.serviceAgent()` gives its address (and creates the agent,
which nothing else does). Google's documentation says the caller needs
no access to the key itself.
**Measured, a create naming a key the agent may not use, or one that
does not exist, is refused at once** with `error.KeyUnavailable`, and
nothing is created.

## Changing keys

`update` changes them, for versions added afterwards only: existing
versions stay wrapped by the key version that wrapped them, readable as
long as it is.

| Secret | Update |
| --- | --- |
| Automatic or regional | `.kms_key = .{ .set = new_key }`, or `.clear` for Google's encryption |
| User-managed | `.replica_keys = &.{ ... }`, every replica in the locations it has, each with its key or null |

A user-managed secret's locations, and the kind of replication, cannot
change: production refuses either, as `error.InvalidArgument`. Rotating
the key in Cloud KMS, so that a new key version is primary, likewise
reaches only new versions, and old ones stay readable while their key
versions are enabled.

## When a key goes away

Every refusal from Cloud KMS is `error.KeyUnavailable`, which production
sends as the 400 `FAILED_PRECONDITION` a disabled secret version also
gets; the library tells them apart by Cloud KMS's words, which
`Diagnostics` keeps. Measured on 2026-10-02, each change reached Secret
Manager within a second:

| The key | `access` of a version it wrapped | `addVersion` |
| --- | --- | --- |
| Key version disabled | `KeyUnavailable`, until it is enabled again | `KeyUnavailable` if it is the primary |
| Key version scheduled for destruction | `KeyUnavailable`; once destroyed, the bytes are gone for good | |
| The agent's role revoked | `KeyUnavailable`, until it is granted again | `KeyUnavailable`, by Google's documentation (not measured) |

Versions wrapped by other key versions, or by Google's keys, are not
affected. Cloud KMS bills each key version by the month, and its
operations by the call, to the key's project.
