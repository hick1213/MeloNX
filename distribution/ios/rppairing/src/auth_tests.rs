// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from Madeira; public upstream interoperability vectors.
use super::*;
    // Official idevice PeerDevice::validate_auth_tag interoperability vector.
    const PEER_IRK: [u8; 16] = [
        0x32, 0x0a, 0x7a, 0x64, 0x63, 0xf3, 0x5c, 0xcd,
        0xa4, 0xbb, 0xd6, 0xeb, 0xe3, 0xab, 0xec, 0x8b,
    ];

    fn matches_peer(irk: &[u8], identifier: &CStr, tag: &CStr) -> i32 {
        unsafe {
            melonx_rppairing_validate_auth_tag(irk.as_ptr(), irk.len(), identifier.as_ptr(), tag.as_ptr())
        }
    }

    #[test]
    fn peer_auth_tag_matches_upstream_vector_and_rejects_other_peers() {
        let identifier = c"2BE6E510-0325-4365-923E-B14C6F57DB3A";
        assert_eq!(matches_peer(&PEER_IRK, identifier, c"kXjlTr2l"), 1);
        let mut other = PEER_IRK;
        other[0] ^= 1;
        assert_eq!(matches_peer(&other, identifier, c"kXjlTr2l"), 0);
        assert_eq!(matches_peer(&PEER_IRK, c"other-device", c"kXjlTr2l"), 0);
        assert_eq!(matches_peer(&PEER_IRK, identifier, c"kXjlTr2m"), 0);
    }

    #[test]
    fn peer_auth_tag_rejects_nulls_lengths_and_malformed_txt() {
        let identifier = c"2BE6E510-0325-4365-923E-B14C6F57DB3A";
        let tag = c"kXjlTr2l";
        unsafe {
            assert_eq!(melonx_rppairing_validate_auth_tag(ptr::null(), 16, identifier.as_ptr(), tag.as_ptr()), 0);
            assert_eq!(melonx_rppairing_validate_auth_tag(PEER_IRK.as_ptr(), 16, ptr::null(), tag.as_ptr()), 0);
            assert_eq!(melonx_rppairing_validate_auth_tag(PEER_IRK.as_ptr(), 16, identifier.as_ptr(), ptr::null()), 0);
        }
        for irk in [&PEER_IRK[..0], &PEER_IRK[..15], &[0u8; 17][..]] {
            assert_eq!(matches_peer(irk, identifier, tag), 0);
        }
        assert_eq!(matches_peer(&PEER_IRK, c"", tag), 0);
        for malformed in [c"", c"!XjlTr2l", c"YWJj", c"YWJjZGVmZw=="] {
            assert_eq!(matches_peer(&PEER_IRK, identifier, malformed), 0);
        }
        let bad_utf8 = CStr::from_bytes_with_nul(b"\xff\0").unwrap();
        assert_eq!(matches_peer(&PEER_IRK, bad_utf8, tag), 0);
        assert_eq!(matches_peer(&PEER_IRK, identifier, bad_utf8), 0);
        let oversized = CString::new("a".repeat(256)).unwrap();
        assert_eq!(matches_peer(&PEER_IRK, &oversized, tag), 0);
    }

