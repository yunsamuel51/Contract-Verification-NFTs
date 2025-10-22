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
(define-constant err-insufficient-stake (err u109))
(define-constant err-no-stake-found (err u110))
(define-constant err-stake-locked (err u111))
(define-constant err-dispute-not-found (err u112))
(define-constant err-dispute-already-exists (err u113))
(define-constant err-dispute-period-ended (err u114))
(define-constant err-insufficient-challenge-stake (err u115))
(define-constant err-already-voted (err u116))
(define-constant err-invalid-dispute-status (err u117))
(define-constant err-invalid-renewal-config (err u118))
(define-constant err-renewal-not-found (err u119))
(define-constant err-insufficient-renewal-balance (err u120))

(define-non-fungible-token verification-certificate uint)

(define-data-var last-token-id uint u0)
(define-data-var verification-fee uint u1000000)
(define-data-var min-verification-duration uint u144)
(define-data-var staking-yield-rate uint u5)
(define-data-var min-stake-amount uint u10000000)
(define-data-var dispute-period uint u1008)
(define-data-var min-challenge-stake uint u5000000)
(define-data-var dispute-id-counter uint u0)
(define-data-var auto-renewal-buffer-blocks uint u144)
(define-data-var renewal-fee-multiplier uint u110)

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

(define-data-var history-entry-id uint u0)

(define-map verification-history
    uint
    {
        contract-address: principal,
        token-id: uint,
        event-type: (string-ascii 20),
        verification-level: (string-ascii 20),
        verified-by: principal,
        block-height: uint,
        expiry-block: uint,
        previous-entry: (optional uint),
    }
)

(define-map contract-history-index
    principal
    {
        latest-entry: (optional uint),
        total-entries: uint,
    }
)

(define-map verification-stakes
    uint
    {
        staker: principal,
        amount: uint,
        start-block: uint,
        lock-duration: uint,
        yield-claimed: uint,
    }
)

(define-map staker-positions
    principal
    {
        active-stakes: (list 10 uint),
        total-staked: uint,
        total-rewards: uint,
    }
)

(define-map verification-disputes
    uint
    {
        token-id: uint,
        challenger: principal,
        challenge-reason: (string-utf8 256),
        challenge-stake: uint,
        challenge-block: uint,
        votes-for: uint,
        votes-against: uint,
        total-voters: uint,
        status: (string-ascii 20),
        resolution-block: (optional uint),
    }
)

(define-map dispute-votes
    {
        dispute-id: uint,
        voter: principal,
    }
    {
        vote: bool,
        voting-power: uint,
        vote-block: uint,
    }
)

(define-map token-disputes
    uint
    {
        active-dispute-id: (optional uint),
        dispute-count: uint,
    }
)

(define-map auto-renewal-configs
    uint
    {
        is-enabled: bool,
        renewal-duration: uint,
        prepaid-balance: uint,
        max-renewals: uint,
        renewals-used: uint,
        buffer-blocks: uint,
        last-renewal-block: uint,
    }
)

(define-map contract-auto-renewals
    principal
    {
        token-id: uint,
        is-active: bool,
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

(define-public (challenge-verification
        (token-id uint)
        (challenge-reason (string-utf8 256))
        (challenge-stake uint)
    )
    (let (
            (token-meta (unwrap! (map-get? token-metadata token-id) err-not-found))
            (current-disputes (default-to {
                active-dispute-id: none,
                dispute-count: u0,
            }
                (map-get? token-disputes token-id)
            ))
            (dispute-id (+ (var-get dispute-id-counter) u1))
        )
        (asserts! (>= challenge-stake (var-get min-challenge-stake))
            err-insufficient-challenge-stake
        )
        (asserts! (is-none (get active-dispute-id current-disputes))
            err-dispute-already-exists
        )
        (asserts! (> (get expiry-block token-meta) stacks-block-height)
            err-verification-expired
        )

        (unwrap!
            (stx-transfer? challenge-stake tx-sender (as-contract tx-sender))
            err-transfer-failed
        )

        (map-set verification-disputes dispute-id {
            token-id: token-id,
            challenger: tx-sender,
            challenge-reason: challenge-reason,
            challenge-stake: challenge-stake,
            challenge-block: stacks-block-height,
            votes-for: u0,
            votes-against: u0,
            total-voters: u0,
            status: "active",
            resolution-block: none,
        })

        (map-set token-disputes token-id {
            active-dispute-id: (some dispute-id),
            dispute-count: (+ (get dispute-count current-disputes) u1),
        })

        (var-set dispute-id-counter dispute-id)
        (ok dispute-id)
    )
)

(define-public (vote-on-dispute
        (dispute-id uint)
        (vote-for bool)
    )
    (let (
            (dispute-info (unwrap! (map-get? verification-disputes dispute-id)
                err-dispute-not-found
            ))
            (existing-vote (map-get? dispute-votes {
                dispute-id: dispute-id,
                voter: tx-sender,
            }))
            (voter-position (unwrap! (map-get? staker-positions tx-sender) err-no-stake-found))
            (voting-power (get total-staked voter-position))
        )
        (asserts! (is-eq (get status dispute-info) "active")
            err-invalid-dispute-status
        )
        (asserts! (is-none existing-vote) err-already-voted)
        (asserts!
            (<= (+ (get challenge-block dispute-info) (var-get dispute-period))
                stacks-block-height
            )
            err-dispute-period-ended
        )
        (asserts! (> voting-power u0) err-insufficient-stake)

        (map-set dispute-votes {
            dispute-id: dispute-id,
            voter: tx-sender,
        } {
            vote: vote-for,
            voting-power: voting-power,
            vote-block: stacks-block-height,
        })

        (map-set verification-disputes dispute-id
            (merge dispute-info {
                votes-for: (if vote-for
                    (+ (get votes-for dispute-info) voting-power)
                    (get votes-for dispute-info)
                ),
                votes-against: (if vote-for
                    (get votes-against dispute-info)
                    (+ (get votes-against dispute-info) voting-power)
                ),
                total-voters: (+ (get total-voters dispute-info) u1),
            })
        )

        (ok true)
    )
)

(define-public (resolve-dispute (dispute-id uint))
    (let (
            (dispute-info (unwrap! (map-get? verification-disputes dispute-id)
                err-dispute-not-found
            ))
            (token-id (get token-id dispute-info))
            (dispute-end-block (+ (get challenge-block dispute-info) (var-get dispute-period)))
            (votes-for (get votes-for dispute-info))
            (votes-against (get votes-against dispute-info))
            (challenge-successful (> votes-for votes-against))
            (challenger (get challenger dispute-info))
            (challenge-stake (get challenge-stake dispute-info))
            (token-disputes-info (unwrap! (map-get? token-disputes token-id) err-dispute-not-found))
        )
        (asserts! (is-eq (get status dispute-info) "active")
            err-invalid-dispute-status
        )
        (asserts! (>= stacks-block-height dispute-end-block)
            err-dispute-period-ended
        )

        (if challenge-successful
            (begin
                (let ((contract-addr (get contract-address
                        (unwrap-panic (map-get? token-metadata token-id))
                    )))
                    (map-set contract-verifications contract-addr {
                        token-id: token-id,
                        is-active: false,
                        verification-count: (get verification-count
                            (unwrap-panic (map-get? contract-verifications contract-addr))
                        ),
                    })
                )
                (unwrap!
                    (as-contract (stx-transfer? challenge-stake tx-sender challenger))
                    err-transfer-failed
                )
            )
            (unwrap!
                (as-contract (stx-transfer? challenge-stake tx-sender (as-contract tx-sender)))
                err-transfer-failed
            )
        )

        (map-set verification-disputes dispute-id
            (merge dispute-info {
                status: (if challenge-successful
                    "upheld"
                    "rejected"
                ),
                resolution-block: (some stacks-block-height),
            })
        )

        (map-set token-disputes token-id
            (merge token-disputes-info { active-dispute-id: none })
        )

        (ok challenge-successful)
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

(define-read-only (get-stake-info (token-id uint))
    (match (map-get? verification-stakes token-id)
        stake (ok stake)
        (err err-no-stake-found)
    )
)

(define-read-only (get-staker-position (staker principal))
    (match (map-get? staker-positions staker)
        position (ok position)
        (ok {
            active-stakes: (list),
            total-staked: u0,
            total-rewards: u0,
        })
    )
)

(define-read-only (calculate-staking-rewards (token-id uint))
    (match (map-get? verification-stakes token-id)
        stake (let (
                (blocks-staked (- stacks-block-height (get start-block stake)))
                (annual-rate (var-get staking-yield-rate))
                (rewards-per-block (/ (* (get amount stake) annual-rate) (* u100 u52560)))
                (total-rewards (* rewards-per-block blocks-staked))
                (unclaimed-rewards (- total-rewards (get yield-claimed stake)))
            )
            (ok unclaimed-rewards)
        )
        (err err-no-stake-found)
    )
)

(define-read-only (get-staking-params)
    (ok {
        yield-rate: (var-get staking-yield-rate),
        min-stake: (var-get min-stake-amount),
    })
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

(define-read-only (get-verification-history-entry (entry-id uint))
    (match (map-get? verification-history entry-id)
        entry (ok entry)
        (err err-not-found)
    )
)

(define-read-only (get-contract-history-summary (contract-address principal))
    (match (map-get? contract-history-index contract-address)
        index (ok index)
        (ok {
            latest-entry: none,
            total-entries: u0,
        })
    )
)

(define-read-only (get-dispute-info (dispute-id uint))
    (match (map-get? verification-disputes dispute-id)
        dispute (ok dispute)
        (err err-dispute-not-found)
    )
)

(define-read-only (get-token-dispute-status (token-id uint))
    (match (map-get? token-disputes token-id)
        disputes (ok disputes)
        (ok {
            active-dispute-id: none,
            dispute-count: u0,
        })
    )
)

(define-read-only (get-dispute-vote
        (dispute-id uint)
        (voter principal)
    )
    (match (map-get? dispute-votes {
        dispute-id: dispute-id,
        voter: voter,
    })
        vote (ok (some vote))
        (ok none)
    )
)

(define-read-only (get-dispute-params)
    (ok {
        dispute-period: (var-get dispute-period),
        min-challenge-stake: (var-get min-challenge-stake),
    })
)

(define-read-only (get-auto-renewal-config (token-id uint))
    (match (map-get? auto-renewal-configs token-id)
        config (ok config)
        (err err-renewal-not-found)
    )
)

(define-read-only (get-contract-auto-renewal-status (contract-address principal))
    (match (map-get? contract-auto-renewals contract-address)
        renewal (ok renewal)
        (ok {
            token-id: u0,
            is-active: false,
        })
    )
)

(define-read-only (check-renewal-eligibility (token-id uint))
    (match (map-get? token-metadata token-id)
        token-meta (match (map-get? auto-renewal-configs token-id)
            renewal-config (let (
                    (blocks-until-expiry (- (get expiry-block token-meta) stacks-block-height))
                    (buffer-blocks (get buffer-blocks renewal-config))
                    (level-info (unwrap-panic (map-get? verification-levels
                        (get verification-level token-meta)
                    )))
                    (renewal-fee (/
                        (* (get base-fee level-info)
                            (var-get renewal-fee-multiplier)
                        )
                        u100
                    ))
                )
                (ok {
                    is-eligible: (and
                        (get is-enabled renewal-config)
                        (<= blocks-until-expiry buffer-blocks)
                        (>= (get prepaid-balance renewal-config) renewal-fee)
                        (< (get renewals-used renewal-config)
                            (get max-renewals renewal-config)
                        )
                    ),
                    blocks-until-expiry: blocks-until-expiry,
                    renewal-fee: renewal-fee,
                    prepaid-balance: (get prepaid-balance renewal-config),
                    renewals-remaining: (- (get max-renewals renewal-config)
                        (get renewals-used renewal-config)
                    ),
                })
            )
            (err err-renewal-not-found)
        )
        (err err-not-found)
    )
)

(define-read-only (get-renewal-params)
    (ok {
        buffer-blocks: (var-get auto-renewal-buffer-blocks),
        fee-multiplier: (var-get renewal-fee-multiplier),
    })
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

(define-public (update-staking-yield-rate (new-rate uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (<= new-rate u20) err-owner-only)
        (var-set staking-yield-rate new-rate)
        (ok true)
    )
)

(define-public (update-min-stake-amount (new-amount uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set min-stake-amount new-amount)
        (ok true)
    )
)

(define-public (setup-auto-renewal
        (token-id uint)
        (renewal-duration uint)
        (max-renewals uint)
        (prepaid-amount uint)
    )
    (let (
            (token-meta (unwrap! (map-get? token-metadata token-id) err-not-found))
            (token-owner (unwrap! (nft-get-owner? verification-certificate token-id)
                err-not-found
            ))
            (level-info (unwrap!
                (map-get? verification-levels (get verification-level token-meta))
                err-invalid-verification-level
            ))
            (renewal-fee (/ (* (get base-fee level-info) (var-get renewal-fee-multiplier))
                u100
            ))
            (min-prepaid (/ (* renewal-fee max-renewals) u1))
        )
        (asserts! (is-eq tx-sender token-owner) err-not-token-owner)
        (asserts! (>= renewal-duration (get min-duration level-info))
            err-invalid-renewal-config
        )
        (asserts! (> max-renewals u0) err-invalid-renewal-config)
        (asserts! (>= prepaid-amount min-prepaid) err-insufficient-payment)

        (unwrap! (stx-transfer? prepaid-amount tx-sender (as-contract tx-sender))
            err-transfer-failed
        )

        (map-set auto-renewal-configs token-id {
            is-enabled: true,
            renewal-duration: renewal-duration,
            prepaid-balance: prepaid-amount,
            max-renewals: max-renewals,
            renewals-used: u0,
            buffer-blocks: (var-get auto-renewal-buffer-blocks),
            last-renewal-block: u0,
        })

        (map-set contract-auto-renewals (get contract-address token-meta) {
            token-id: token-id,
            is-active: true,
        })

        (ok true)
    )
)

(define-public (add-renewal-funds
        (token-id uint)
        (additional-amount uint)
    )
    (let (
            (token-owner (unwrap! (nft-get-owner? verification-certificate token-id)
                err-not-found
            ))
            (renewal-config (unwrap! (map-get? auto-renewal-configs token-id)
                err-renewal-not-found
            ))
        )
        (asserts! (is-eq tx-sender token-owner) err-not-token-owner)
        (asserts! (> additional-amount u0) err-insufficient-payment)

        (unwrap!
            (stx-transfer? additional-amount tx-sender (as-contract tx-sender))
            err-transfer-failed
        )

        (map-set auto-renewal-configs token-id
            (merge renewal-config { prepaid-balance: (+ (get prepaid-balance renewal-config) additional-amount) })
        )

        (ok (+ (get prepaid-balance renewal-config) additional-amount))
    )
)

(define-public (execute-auto-renewal (token-id uint))
    (let (
            (token-meta (unwrap! (map-get? token-metadata token-id) err-not-found))
            (renewal-config (unwrap! (map-get? auto-renewal-configs token-id)
                err-renewal-not-found
            ))
            (level-info (unwrap!
                (map-get? verification-levels (get verification-level token-meta))
                err-invalid-verification-level
            ))
            (renewal-fee (/ (* (get base-fee level-info) (var-get renewal-fee-multiplier))
                u100
            ))
            (blocks-until-expiry (- (get expiry-block token-meta) stacks-block-height))
        )
        (asserts! (get is-enabled renewal-config) err-invalid-renewal-config)
        (asserts! (<= blocks-until-expiry (get buffer-blocks renewal-config))
            err-invalid-renewal-config
        )
        (asserts! (>= (get prepaid-balance renewal-config) renewal-fee)
            err-insufficient-renewal-balance
        )
        (asserts!
            (< (get renewals-used renewal-config)
                (get max-renewals renewal-config)
            )
            err-invalid-renewal-config
        )

        (map-set token-metadata token-id
            (merge token-meta { expiry-block: (+ (get expiry-block token-meta)
                (get renewal-duration renewal-config)
            ) }
            ))

        (map-set auto-renewal-configs token-id
            (merge renewal-config {
                prepaid-balance: (- (get prepaid-balance renewal-config) renewal-fee),
                renewals-used: (+ (get renewals-used renewal-config) u1),
                last-renewal-block: stacks-block-height,
            })
        )

        (ok {
            new-expiry: (+ (get expiry-block token-meta)
                (get renewal-duration renewal-config)
            ),
            fee-charged: renewal-fee,
            remaining-balance: (- (get prepaid-balance renewal-config) renewal-fee),
            renewals-remaining: (- (get max-renewals renewal-config)
                (+ (get renewals-used renewal-config) u1)
            ),
        })
    )
)

(define-public (disable-auto-renewal (token-id uint))
    (let (
            (token-owner (unwrap! (nft-get-owner? verification-certificate token-id)
                err-not-found
            ))
            (renewal-config (unwrap! (map-get? auto-renewal-configs token-id)
                err-renewal-not-found
            ))
            (token-meta (unwrap! (map-get? token-metadata token-id) err-not-found))
            (refund-amount (get prepaid-balance renewal-config))
        )
        (asserts! (is-eq tx-sender token-owner) err-not-token-owner)

        (map-set auto-renewal-configs token-id
            (merge renewal-config {
                is-enabled: false,
                prepaid-balance: u0,
            })
        )

        (map-set contract-auto-renewals (get contract-address token-meta) {
            token-id: token-id,
            is-active: false,
        })

        (if (> refund-amount u0)
            (unwrap!
                (as-contract (stx-transfer? refund-amount tx-sender token-owner))
                err-transfer-failed
            )
            true
        )

        (ok refund-amount)
    )
)

(define-public (update-renewal-buffer (new-buffer uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (>= new-buffer u144) err-invalid-renewal-config)
        (var-set auto-renewal-buffer-blocks new-buffer)
        (ok true)
    )
)

(define-public (update-renewal-fee-multiplier (new-multiplier uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (>= new-multiplier u100) err-invalid-renewal-config)
        (asserts! (<= new-multiplier u200) err-invalid-renewal-config)
        (var-set renewal-fee-multiplier new-multiplier)
        (ok true)
    )
)

(define-public (burn (token-id uint))
    (let ((token-owner (unwrap! (nft-get-owner? verification-certificate token-id) err-not-found)))
        (asserts! (is-eq tx-sender token-owner) err-not-token-owner)
        (nft-burn? verification-certificate token-id token-owner)
    )
)

(define-public (stake-for-verification
        (token-id uint)
        (stake-amount uint)
        (lock-blocks uint)
    )
    (let (
            (token-owner (unwrap! (nft-get-owner? verification-certificate token-id)
                err-not-found
            ))
            (current-position (default-to {
                active-stakes: (list),
                total-staked: u0,
                total-rewards: u0,
            }
                (map-get? staker-positions tx-sender)
            ))
        )
        (asserts! (is-eq tx-sender token-owner) err-not-token-owner)
        (asserts! (>= stake-amount (var-get min-stake-amount))
            err-insufficient-stake
        )
        (asserts! (>= lock-blocks u1008) err-verification-expired)

        (unwrap! (stx-transfer? stake-amount tx-sender (as-contract tx-sender))
            err-transfer-failed
        )

        (map-set verification-stakes token-id {
            staker: tx-sender,
            amount: stake-amount,
            start-block: stacks-block-height,
            lock-duration: lock-blocks,
            yield-claimed: u0,
        })

        (let ((updated-stakes (unwrap!
                (as-max-len?
                    (append (get active-stakes current-position) token-id)
                    u10
                )
                err-insufficient-stake
            )))
            (map-set staker-positions tx-sender {
                active-stakes: updated-stakes,
                total-staked: (+ (get total-staked current-position) stake-amount),
                total-rewards: (get total-rewards current-position),
            })
        )

        (ok token-id)
    )
)

(define-public (claim-staking-rewards (token-id uint))
    (let (
            (stake-info (unwrap! (map-get? verification-stakes token-id) err-no-stake-found))
            (token-owner (unwrap! (nft-get-owner? verification-certificate token-id)
                err-not-found
            ))
            (rewards (unwrap! (calculate-staking-rewards token-id) err-no-stake-found))
            (current-position (unwrap! (map-get? staker-positions tx-sender) err-no-stake-found))
        )
        (asserts! (is-eq tx-sender token-owner) err-not-token-owner)
        (asserts! (is-eq tx-sender (get staker stake-info)) err-not-token-owner)
        (asserts! (> rewards u0) err-insufficient-stake)

        (unwrap! (as-contract (stx-transfer? rewards tx-sender tx-sender))
            err-transfer-failed
        )

        (map-set verification-stakes token-id
            (merge stake-info { yield-claimed: (+ (get yield-claimed stake-info) rewards) })
        )

        (map-set staker-positions tx-sender
            (merge current-position { total-rewards: (+ (get total-rewards current-position) rewards) })
        )

        (ok rewards)
    )
)

(define-public (unstake-verification (token-id uint))
    (let (
            (stake-info (unwrap! (map-get? verification-stakes token-id) err-no-stake-found))
            (token-owner (unwrap! (nft-get-owner? verification-certificate token-id)
                err-not-found
            ))
            (unlock-block (+ (get start-block stake-info) (get lock-duration stake-info)))
            (current-position (unwrap! (map-get? staker-positions tx-sender) err-no-stake-found))
            (rewards (unwrap! (calculate-staking-rewards token-id) err-no-stake-found))
            (total-return (+ (get amount stake-info) rewards))
        )
        (asserts! (is-eq tx-sender token-owner) err-not-token-owner)
        (asserts! (is-eq tx-sender (get staker stake-info)) err-not-token-owner)
        (asserts! (>= stacks-block-height unlock-block) err-stake-locked)

        (unwrap! (as-contract (stx-transfer? total-return tx-sender tx-sender))
            err-transfer-failed
        )

        (let (
                (filter-result (filter-stakes (get active-stakes current-position) token-id))
                (updated-stakes (get result filter-result))
            )
            (map-set staker-positions tx-sender {
                active-stakes: updated-stakes,
                total-staked: (- (get total-staked current-position) (get amount stake-info)),
                total-rewards: (+ (get total-rewards current-position) rewards),
            })
        )

        (map-delete verification-stakes token-id)
        (ok total-return)
    )
)

(define-private (filter-stakes
        (stakes (list 10 uint))
        (remove-id uint)
    )
    (fold build-filtered-list stakes {
        target-id: remove-id,
        result: (list),
    })
)

(define-private (build-filtered-list
        (stake-id uint)
        (state {
            target-id: uint,
            result: (list 10 uint),
        })
    )
    (if (is-eq stake-id (get target-id state))
        state
        {
            target-id: (get target-id state),
            result: (unwrap-panic (as-max-len? (append (get result state) stake-id) u10)),
        }
    )
)

(define-public (batch-verify-contracts (contracts (list
    10
    {
        address: principal,
        level: (string-ascii 20),
        duration: uint,
    }
)))
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
