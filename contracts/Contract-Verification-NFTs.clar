(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-token-owner (err u101))
(define-constant err-not-found (err u102))
(define-constant err-already-verified (err u103))
(define-constant err-verification-expired (err u104))
(define-constant err-invalid-verification-level (err u105))
(define-constant err-insufficient-payment (err u106))
(define-constant err-transfer-failed (err u107))
(define-constant err-mint-failed (err u108))

(define-non-fungible-token verification-certificate uint)

(define-data-var last-token-id uint u0)
(define-data-var verification-fee uint u1000000)
(define-data-var min-verification-duration uint u144)

(define-map token-metadata
    uint
    {
        contract-address: principal,
        verification-level: (string-ascii 20),
        verified-by: principal,
        verification-date: uint,
        expiry-block: uint,
        metadata-uri: (optional (string-utf8 256)),
    }
)

(define-map contract-verifications
    principal
    {
        token-id: uint,
        is-active: bool,
        verification-count: uint,
    }
)

(define-map verifier-registry
    principal
    {
        is-authorized: bool,
        verification-count: uint,
        reputation-score: uint,
    }
)

(define-map verification-levels
    (string-ascii 20)
    {
        min-duration: uint,
        base-fee: uint,
        required-reputation: uint,
    }
)

(define-read-only (get-last-token-id)
    (ok (var-get last-token-id))
)

(define-read-only (get-token-uri (token-id uint))
    (match (map-get? token-metadata token-id)
        metadata (ok (get metadata-uri metadata))
        (err err-not-found)
    )
)

(define-read-only (get-owner (token-id uint))
    (ok (nft-get-owner? verification-certificate token-id))
)

(define-read-only (get-token-metadata (token-id uint))
    (match (map-get? token-metadata token-id)
        metadata (ok metadata)
        (err err-not-found)
    )
)

(define-read-only (get-contract-verification (contract-address principal))
    (match (map-get? contract-verifications contract-address)
        verification (ok verification)
        (err err-not-found)
    )
)

(define-read-only (is-contract-verified (contract-address principal))
    (match (map-get? contract-verifications contract-address)
        verification (let ((token-meta (unwrap-panic (map-get? token-metadata (get token-id verification)))))
            (and
                (get is-active verification)
                (> (get expiry-block token-meta) stacks-block-height)
            )
        )
        false
    )
)

(define-read-only (get-verifier-info (verifier principal))
    (match (map-get? verifier-registry verifier)
        info (ok info)
        (err err-not-found)
    )
)

(define-read-only (get-verification-level-info (level (string-ascii 20)))
    (match (map-get? verification-levels level)
        info (ok info)
        (err err-not-found)
    )
)

(define-read-only (get-verification-fee)
    (ok (var-get verification-fee))
)

(define-read-only (get-verification-status (contract-address principal))
    (match (map-get? contract-verifications contract-address)
        verification (match (map-get? token-metadata (get token-id verification))
            metadata (ok {
                is-verified: (and
                    (get is-active verification)
                    (> (get expiry-block metadata) stacks-block-height)
                ),
                verification-level: (get verification-level metadata),
                verified-by: (get verified-by metadata),
                verification-date: (get verification-date metadata),
                expiry-block: (get expiry-block metadata),
                verification-count: (get verification-count verification),
            })
            (err err-not-found)
        )
        (ok {
            is-verified: false,
            verification-level: "none",
            verified-by: contract-owner,
            verification-date: u0,
            expiry-block: u0,
            verification-count: u0,
        })
    )
)

(define-public (transfer
        (token-id uint)
        (sender principal)
        (recipient principal)
    )
    (begin
        (asserts! (is-eq tx-sender sender) err-not-token-owner)
        (nft-transfer? verification-certificate token-id sender recipient)
    )
)

(define-public (mint-verification-certificate
        (contract-address principal)
        (verification-level (string-ascii 20))
        (duration-blocks uint)
        (metadata-uri (optional (string-utf8 256)))
    )
    (let (
            (token-id (+ (var-get last-token-id) u1))
            (expiry-block (+ stacks-block-height duration-blocks))
            (level-info (unwrap! (map-get? verification-levels verification-level)
                err-invalid-verification-level
            ))
            (verifier-info (default-to {
                is-authorized: false,
                verification-count: u0,
                reputation-score: u0,
            }
                (map-get? verifier-registry tx-sender)
            ))
            (required-fee (get base-fee level-info))
        )
        (asserts! (>= duration-blocks (get min-duration level-info))
            err-verification-expired
        )
        (asserts! (get is-authorized verifier-info) err-owner-only)
        (asserts!
            (>= (get reputation-score verifier-info)
                (get required-reputation level-info)
            )
            err-owner-only
        )

        (unwrap! (stx-transfer? required-fee tx-sender contract-owner)
            err-transfer-failed
        )
        (unwrap! (nft-mint? verification-certificate token-id contract-address)
            err-mint-failed
        )

        (map-set token-metadata token-id {
            contract-address: contract-address,
            verification-level: verification-level,
            verified-by: tx-sender,
            verification-date: stacks-block-height,
            expiry-block: expiry-block,
            metadata-uri: metadata-uri,
        })

        (let ((current-verification (default-to {
                token-id: u0,
                is-active: false,
                verification-count: u0,
            }
                (map-get? contract-verifications contract-address)
            )))
            (map-set contract-verifications contract-address {
                token-id: token-id,
                is-active: true,
                verification-count: (+ (get verification-count current-verification) u1),
            })
        )

        (map-set verifier-registry tx-sender {
            is-authorized: (get is-authorized verifier-info),
            verification-count: (+ (get verification-count verifier-info) u1),
            reputation-score: (+ (get reputation-score verifier-info) u10),
        })

        (var-set last-token-id token-id)
        (ok token-id)
    )
)

(define-public (revoke-verification (token-id uint))
    (let (
            (token-meta (unwrap! (map-get? token-metadata token-id) err-not-found))
            (contract-addr (get contract-address token-meta))
            (current-verification (unwrap! (map-get? contract-verifications contract-addr)
                err-not-found
            ))
        )
        (asserts!
            (or
                (is-eq tx-sender contract-owner)
                (is-eq tx-sender (get verified-by token-meta))
            )
            err-owner-only
        )

        (map-set contract-verifications contract-addr {
            token-id: token-id,
            is-active: false,
            verification-count: (get verification-count current-verification),
        })

        (ok true)
    )
)

(define-public (extend-verification
        (token-id uint)
        (additional-blocks uint)
    )
    (let (
            (token-meta (unwrap! (map-get? token-metadata token-id) err-not-found))
            (current-owner (unwrap! (nft-get-owner? verification-certificate token-id)
                err-not-found
            ))
            (level-info (unwrap!
                (map-get? verification-levels (get verification-level token-meta))
                err-invalid-verification-level
            ))
            (extension-fee (/ (* (get base-fee level-info) additional-blocks) u1008))
        )
        (asserts! (is-eq tx-sender current-owner) err-not-token-owner)
        (asserts! (>= additional-blocks (var-get min-verification-duration))
            err-verification-expired
        )

        (unwrap! (stx-transfer? extension-fee tx-sender contract-owner)
            err-transfer-failed
        )

        (map-set token-metadata token-id
            (merge token-meta { expiry-block: (+ (get expiry-block token-meta) additional-blocks) })
        )

        (ok true)
    )
)

(define-public (register-verifier (verifier principal))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)

        (map-set verifier-registry verifier {
            is-authorized: true,
            verification-count: u0,
            reputation-score: u50,
        })

        (ok true)
    )
)

(define-public (remove-verifier (verifier principal))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)

        (let ((current-info (default-to {
                is-authorized: false,
                verification-count: u0,
                reputation-score: u0,
            }
                (map-get? verifier-registry verifier)
            )))
            (map-set verifier-registry verifier
                (merge current-info { is-authorized: false })
            )
        )

        (ok true)
    )
)

(define-public (set-verification-level
        (level (string-ascii 20))
        (min-duration uint)
        (base-fee uint)
        (required-reputation uint)
    )
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)

        (map-set verification-levels level {
            min-duration: min-duration,
            base-fee: base-fee,
            required-reputation: required-reputation,
        })

        (ok true)
    )
)

(define-public (update-verification-fee (new-fee uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set verification-fee new-fee)
        (ok true)
    )
)

(define-public (update-min-verification-duration (new-duration uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set min-verification-duration new-duration)
        (ok true)
    )
)

(define-public (burn (token-id uint))
    (let ((token-owner (unwrap! (nft-get-owner? verification-certificate token-id) err-not-found)))
        (asserts! (is-eq tx-sender token-owner) err-not-token-owner)
        (nft-burn? verification-certificate token-id token-owner)
    )
)

(define-public (batch-verify-contracts (contracts (list 10
    {
    address: principal,
    level: (string-ascii 20),
    duration: uint,
})))
    (let ((verifier-info (unwrap! (map-get? verifier-registry tx-sender) err-owner-only)))
        (asserts! (get is-authorized verifier-info) err-owner-only)
        (ok (map verify-single-contract contracts))
    )
)

(define-private (verify-single-contract (contract-data {
    address: principal,
    level: (string-ascii 20),
    duration: uint,
}))
    (let (
            (token-id (+ (var-get last-token-id) u1))
            (level-info (unwrap-panic (map-get? verification-levels (get level contract-data))))
            (required-fee (get base-fee level-info))
        )
        (var-set last-token-id token-id)
        (unwrap-panic (nft-mint? verification-certificate token-id (get address contract-data)))

        (map-set token-metadata token-id {
            contract-address: (get address contract-data),
            verification-level: (get level contract-data),
            verified-by: tx-sender,
            verification-date: stacks-block-height,
            expiry-block: (+ stacks-block-height (get duration contract-data)),
            metadata-uri: none,
        })

        (map-set contract-verifications (get address contract-data) {
            token-id: token-id,
            is-active: true,
            verification-count: u1,
        })

        token-id
    )
)

(begin
    (map-set verification-levels "basic" {
        min-duration: u144,
        base-fee: u500000,
        required-reputation: u0,
    })
    (map-set verification-levels "standard" {
        min-duration: u1008,
        base-fee: u2000000,
        required-reputation: u50,
    })
    (map-set verification-levels "premium" {
        min-duration: u4032,
        base-fee: u10000000,
        required-reputation: u100,
    })
    (map-set verification-levels "enterprise" {
        min-duration: u8064,
        base-fee: u50000000,
        required-reputation: u200,
    })
)
