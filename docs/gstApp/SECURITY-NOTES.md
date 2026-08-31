# Security Notes

## Known Security Issues and Deferral Rationale

### 1. AES Hardcoded Key (aes.cpp)

**Status:** ⚠️ DEFERRED (Not fixed in current release)

**Location:**
- `aes.cpp:262` - `encrypt_get_passwd()`
- `aes.cpp:308` - `encrypt_change_passwd()`

**Issue:**
The AES encryption functions use a hardcoded NIST test vector as the encryption key:
```cpp
BYTE Key[] = {0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6,
              0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c};
```

This is a publicly known test vector from FIPS-197 (AES specification), making encrypted passwords vulnerable to decryption by anyone with access to the encrypted file.

**Security Impact:**
- **Severity:** Critical
- **Attack Vector:** Local file access
- **Affected Functions:** Password storage and password change operations
- **Exploitability:** High (known key value)

**Why Deferred:**
1. **Backward Compatibility:** Deployed production devices already use this encryption key
2. **User Impact:** Changing the key would invalidate all existing stored passwords
3. **Migration Complexity:** No automated migration path exists for field-deployed units
4. **Customer Disruption:** Users would lose access and require manual password reset

**Deferral Decision Date:** 2026-01-20

**Mitigation in Place:**
- Password files should have restrictive permissions (600 or 640)
- Physical access control to deployed devices
- Network isolation of management interfaces

**Recommended Fix (For Future Major Version):**
```cpp
// Option 1: Load key from secure storage
int load_encryption_key(const char *keyfile, BYTE *key, size_t keylen);

// Option 2: Derive key from device-unique identifier
int derive_device_key(BYTE *key, size_t keylen);

// Option 3: Use TPM/HSM for key storage
int get_tpm_key(BYTE *key, size_t keylen);

// Migration path required:
// 1. Detect old encryption format
// 2. Decrypt with old key
// 3. Re-encrypt with new key
// 4. Mark as migrated
```

**Migration Strategy (Future):**
1. Implement key versioning in password file format
2. Support both old and new keys during transition period
3. Auto-migrate on first password change
4. Provide manual migration tool for field deployment
5. Deprecation timeline: 1-2 year overlap period

**References:**
- NIST FIPS-197: https://csrc.nist.gov/publications/detail/fips/197/final
- CWE-321: Use of Hard-coded Cryptographic Key
- OWASP: Cryptographic Storage Cheat Sheet

---

### 2. Legacy Command Injection Risk (util.cpp)

**Status:** ⚠️ ACCEPTED RISK (Mitigated by input constraints)

**Location:** `util.cpp:360-388` - `search_file()`

**Issue:**
Function uses `popen()` with shell command pipeline:
```cpp
sprintf(str, "ls -ptr %s/%s*%s 2>/dev/null | grep -v '/$' | grep '\\%s$' | tail -1 ...",
        path, prefix, suffix, suffix);
fp = popen(str, "r");
```

**Security Impact:**
- **Severity:** Medium (if inputs are user-controlled)
- **Attack Vector:** Command injection via path/prefix/suffix
- **Current Mitigation:** Function is only called with hardcoded internal constants

**Risk Acceptance Rationale:**
- All call sites use compile-time constants
- No external input reaches this function
- Previous GLib implementation was reverted for operational reasons

**Call Site Analysis:**
```bash
# Verify all callers use constants only
grep -n "search_file" *.cpp
```

**Required Controls:**
1. ✅ All callers use string literals
2. ✅ No user input flows to this function
3. ⚠️ Code comments warn about input constraints
4. ⚠️ No runtime validation of inputs

**Monitoring:**
- Static analysis should flag any new callers
- Code review must verify input sources
- Annual security audit recommended

**Future Improvement (Low Priority):**
- Add input validation assertions
- Revert to GLib-based implementation
- Add unit tests with malicious inputs

---

## Security Review History

| Date       | Reviewer | Scope                    | Critical Findings |
|------------|----------|--------------------------|-------------------|
| 2026-01-20 | Claude   | Commit diff analysis     | 2 (1 deferred)    |

---

## Reporting Security Issues

If you discover a security vulnerability in this codebase:

1. **Do NOT** open a public GitHub issue
2. Contact the security team directly: [security contact]
3. Provide:
   - Detailed description of the vulnerability
   - Steps to reproduce
   - Potential impact assessment
   - Suggested fix (if available)

Response SLA: 48 hours for acknowledgment

---

## Secure Development Guidelines

### For Developers

1. **Never hardcode secrets or keys**
   - Use environment variables
   - Use secure key storage (HSM/TPM)
   - Use key derivation functions

2. **Avoid shell execution**
   - Prefer native library functions
   - Use argument arrays over shell strings
   - Validate all inputs if shell execution is unavoidable

3. **Input validation**
   - Validate at system boundaries
   - Use allowlists over denylists
   - Sanitize before use in sensitive contexts

4. **Cryptography**
   - Use proven libraries (OpenSSL, libsodium)
   - Follow current best practices
   - Regular key rotation where feasible

### For Code Reviewers

- Check for CWE Top 25 vulnerabilities
- Verify input validation at boundaries
- Ensure secrets are not committed
- Review privilege requirements
- Validate error handling

---

**Last Updated:** 2026-01-20
**Next Review Due:** 2026-07-20
