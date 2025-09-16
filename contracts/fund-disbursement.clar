;; title: fund-disbursement
;; version: 1.0.0
;; summary: Smart contract to release funds to verified students
;; description: A secure system for managing scholarship fund pools,
;; automated disbursement, and transparent tracking of all payments

;; traits
;;

;; token definitions
;;

;; constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u401))
(define-constant ERR_NOT_FOUND (err u404))
(define-constant ERR_ALREADY_EXISTS (err u409))
(define-constant ERR_INVALID_PARAMS (err u400))
(define-constant ERR_INSUFFICIENT_FUNDS (err u402))
(define-constant ERR_ALREADY_DISBURSED (err u406))
(define-constant ERR_NOT_VERIFIED (err u407))
(define-constant ERR_CONTRACT_PAUSED (err u408))

;; Disbursement status constants
(define-constant STATUS_PENDING u1)
(define-constant STATUS_APPROVED u2)
(define-constant STATUS_DISBURSED u3)
(define-constant STATUS_CANCELLED u4)
(define-constant STATUS_REFUNDED u5)

;; Verification status constants
(define-constant VERIFICATION_PENDING u1)
(define-constant VERIFICATION_APPROVED u2)
(define-constant VERIFICATION_REJECTED u3)

;; Fund pool status constants
(define-constant POOL_ACTIVE u1)
(define-constant POOL_PAUSED u2)
(define-constant POOL_CLOSED u3)
(define-constant POOL_EMERGENCY_PAUSE u4)

;; data vars
(define-data-var next-fund-id uint u1)
(define-data-var next-disbursement-id uint u1)
(define-data-var contract-paused bool false)
(define-data-var total-funds-created uint u0)
(define-data-var total-disbursements uint u0)
(define-data-var total-amount-disbursed uint u0)
(define-data-var emergency-contact principal CONTRACT_OWNER)

;; data maps
;; Fund pool management
(define-map fund-pools
  { fund-id: uint }
  {
    scholarship-id: uint,
    fund-manager: principal,
    total-amount: uint,
    available-amount: uint,
    disbursed-amount: uint,
    recipient-count: uint,
    max-recipients: uint,
    status: uint,
    created-at: uint,
    last-disbursement: (optional uint),
    emergency-pause-reason: (optional (string-ascii 200))
  }
)

;; Disbursement records
(define-map disbursements
  { disbursement-id: uint }
  {
    fund-id: uint,
    recipient: principal,
    amount: uint,
    status: uint,
    verification-status: uint,
    requested-at: uint,
    approved-at: (optional uint),
    disbursed-at: (optional uint),
    approver: (optional principal),
    milestone-info: (optional (string-ascii 300)),
    verification-documents: (optional (string-ascii 500))
  }
)

;; Recipient verification tracking
(define-map verified-recipients
  { recipient: principal, fund-id: uint }
  {
    verification-status: uint,
    verified-at: uint,
    verifier: principal,
    student-id: (string-ascii 50),
    institution: (string-ascii 100),
    enrollment-status: bool,
    gpa-verified: bool,
    documents-hash: (string-ascii 64)
  }
)

;; Multi-signature approvers for security
(define-map fund-approvers
  { fund-id: uint }
  {
    approvers: (list 5 principal),
    required-signatures: uint,
    current-signatures: uint
  }
)

;; Track disbursement history for auditing
(define-map disbursement-history
  { fund-id: uint }
  {
    disbursement-ids: (list 100 uint),
    total-disbursed: uint,
    count: uint
  }
)

;; Milestone-based payment tracking
(define-map payment-milestones
  { disbursement-id: uint }
  {
    milestone-1: bool, ;; Initial enrollment verification
    milestone-2: bool, ;; Mid-term progress check
    milestone-3: bool, ;; Final completion verification
    milestone-1-amount: uint,
    milestone-2-amount: uint,
    milestone-3-amount: uint
  }
)

;; Emergency controls
(define-map emergency-controls
  { fund-id: uint }
  {
    can-emergency-pause: bool,
    emergency-contacts: (list 3 principal),
    last-emergency-action: (optional uint)
  }
)

;; public functions

;; Create a new fund pool for scholarship disbursement
(define-public (create-fund-pool
  (scholarship-id uint)
  (total-amount uint)
  (max-recipients uint)
  (required-signatures uint)
  (approvers (list 5 principal))
)
  (let
    (
      (fund-id (var-get next-fund-id))
      (current-block stacks-block-height)
    )
    (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
    (asserts! (> total-amount u0) ERR_INVALID_PARAMS)
    (asserts! (> max-recipients u0) ERR_INVALID_PARAMS)
    (asserts! (and (> required-signatures u0) (<= required-signatures (len approvers))) ERR_INVALID_PARAMS)
    
    ;; Transfer funds to contract (user needs to send STX with transaction)
    (try! (stx-transfer? total-amount tx-sender (as-contract tx-sender)))
    
    ;; Create fund pool
    (map-set fund-pools
      { fund-id: fund-id }
      {
        scholarship-id: scholarship-id,
        fund-manager: tx-sender,
        total-amount: total-amount,
        available-amount: total-amount,
        disbursed-amount: u0,
        recipient-count: u0,
        max-recipients: max-recipients,
        status: POOL_ACTIVE,
        created-at: current-block,
        last-disbursement: none,
        emergency-pause-reason: none
      }
    )
    
    ;; Set up approvers
    (map-set fund-approvers
      { fund-id: fund-id }
      {
        approvers: approvers,
        required-signatures: required-signatures,
        current-signatures: u0
      }
    )
    
    ;; Initialize disbursement history
    (map-set disbursement-history
      { fund-id: fund-id }
      { disbursement-ids: (list), total-disbursed: u0, count: u0 }
    )
    
    ;; Set up emergency controls
    (map-set emergency-controls
      { fund-id: fund-id }
      {
        can-emergency-pause: true,
        emergency-contacts: (list tx-sender (var-get emergency-contact)),
        last-emergency-action: none
      }
    )
    
    ;; Update counters
    (var-set next-fund-id (+ fund-id u1))
    (var-set total-funds-created (+ (var-get total-funds-created) u1))
    
    (ok fund-id)
  )
)

;; Verify a recipient for fund disbursement
(define-public (verify-recipient
  (fund-id uint)
  (recipient principal)
  (student-id (string-ascii 50))
  (institution (string-ascii 100))
  (enrollment-status bool)
  (gpa-verified bool)
  (documents-hash (string-ascii 64))
)
  (let
    (
      (fund (unwrap! (map-get? fund-pools { fund-id: fund-id }) ERR_NOT_FOUND))
      (current-block stacks-block-height)
    )
    (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
    (asserts! (is-fund-manager-or-approver fund-id tx-sender) ERR_UNAUTHORIZED)
    (asserts! (is-eq (get status fund) POOL_ACTIVE) ERR_UNAUTHORIZED)
    
    ;; Create verification record
    (map-set verified-recipients
      { recipient: recipient, fund-id: fund-id }
      {
        verification-status: VERIFICATION_APPROVED,
        verified-at: current-block,
        verifier: tx-sender,
        student-id: student-id,
        institution: institution,
        enrollment-status: enrollment-status,
        gpa-verified: gpa-verified,
        documents-hash: documents-hash
      }
    )
    
    (ok true)
  )
)

;; Disburse funds to a verified recipient
(define-public (disburse-funds
  (fund-id uint)
  (recipient principal)
  (amount uint)
  (milestone-info (string-ascii 300))
)
  (let
    (
      (disbursement-id (var-get next-disbursement-id))
      (fund (unwrap! (map-get? fund-pools { fund-id: fund-id }) ERR_NOT_FOUND))
      (verification (unwrap! (map-get? verified-recipients { recipient: recipient, fund-id: fund-id }) ERR_NOT_VERIFIED))
      (current-block stacks-block-height)
      (history (default-to { disbursement-ids: (list), total-disbursed: u0, count: u0 }
                 (map-get? disbursement-history { fund-id: fund-id })))
    )
    (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
    (asserts! (is-fund-manager-or-approver fund-id tx-sender) ERR_UNAUTHORIZED)
    (asserts! (is-eq (get status fund) POOL_ACTIVE) ERR_UNAUTHORIZED)
    (asserts! (is-eq (get verification-status verification) VERIFICATION_APPROVED) ERR_NOT_VERIFIED)
    (asserts! (>= (get available-amount fund) amount) ERR_INSUFFICIENT_FUNDS)
    (asserts! (< (get recipient-count fund) (get max-recipients fund)) ERR_INVALID_PARAMS)
    
    ;; Create disbursement record
    (map-set disbursements
      { disbursement-id: disbursement-id }
      {
        fund-id: fund-id,
        recipient: recipient,
        amount: amount,
        status: STATUS_APPROVED,
        verification-status: VERIFICATION_APPROVED,
        requested-at: current-block,
        approved-at: (some current-block),
        disbursed-at: none,
        approver: (some tx-sender),
        milestone-info: (some milestone-info),
        verification-documents: none
      }
    )
    
    ;; Execute the transfer
    (try! (as-contract (stx-transfer? amount tx-sender recipient)))
    
    ;; Update disbursement status
    (map-set disbursements
      { disbursement-id: disbursement-id }
      {
        fund-id: fund-id,
        recipient: recipient,
        amount: amount,
        status: STATUS_DISBURSED,
        verification-status: VERIFICATION_APPROVED,
        requested-at: current-block,
        approved-at: (some current-block),
        disbursed-at: (some current-block),
        approver: (some tx-sender),
        milestone-info: (some milestone-info),
        verification-documents: none
      }
    )
    
    ;; Update fund pool
    (map-set fund-pools
      { fund-id: fund-id }
      {
        scholarship-id: (get scholarship-id fund),
        fund-manager: (get fund-manager fund),
        total-amount: (get total-amount fund),
        available-amount: (- (get available-amount fund) amount),
        disbursed-amount: (+ (get disbursed-amount fund) amount),
        recipient-count: (+ (get recipient-count fund) u1),
        max-recipients: (get max-recipients fund),
        status: (get status fund),
        created-at: (get created-at fund),
        last-disbursement: (some current-block),
        emergency-pause-reason: (get emergency-pause-reason fund)
      }
    )
    
    ;; Update disbursement history
    (map-set disbursement-history
      { fund-id: fund-id }
      {
        disbursement-ids: (unwrap! (as-max-len? (append (get disbursement-ids history) disbursement-id) u100) ERR_INVALID_PARAMS),
        total-disbursed: (+ (get total-disbursed history) amount),
        count: (+ (get count history) u1)
      }
    )
    
    ;; Update global counters
    (var-set next-disbursement-id (+ disbursement-id u1))
    (var-set total-disbursements (+ (var-get total-disbursements) u1))
    (var-set total-amount-disbursed (+ (var-get total-amount-disbursed) amount))
    
    (ok disbursement-id)
  )
)

;; Emergency pause function
(define-public (emergency-pause (fund-id uint) (reason (string-ascii 200)))
  (let
    (
      (fund (unwrap! (map-get? fund-pools { fund-id: fund-id }) ERR_NOT_FOUND))
      (emergency-control (unwrap! (map-get? emergency-controls { fund-id: fund-id }) ERR_NOT_FOUND))
    )
    (asserts! (get can-emergency-pause emergency-control) ERR_UNAUTHORIZED)
    (asserts! (is-emergency-contact fund-id tx-sender) ERR_UNAUTHORIZED)
    
    ;; Update fund status
    (map-set fund-pools
      { fund-id: fund-id }
      {
        scholarship-id: (get scholarship-id fund),
        fund-manager: (get fund-manager fund),
        total-amount: (get total-amount fund),
        available-amount: (get available-amount fund),
        disbursed-amount: (get disbursed-amount fund),
        recipient-count: (get recipient-count fund),
        max-recipients: (get max-recipients fund),
        status: POOL_EMERGENCY_PAUSE,
        created-at: (get created-at fund),
        last-disbursement: (get last-disbursement fund),
        emergency-pause-reason: (some reason)
      }
    )
    
    (ok true)
  )
)

;; read only functions

;; Get fund pool details
(define-read-only (get-fund-pool-details (fund-id uint))
  (map-get? fund-pools { fund-id: fund-id })
)

;; Get disbursement details
(define-read-only (get-disbursement-details (disbursement-id uint))
  (map-get? disbursements { disbursement-id: disbursement-id })
)

;; Get disbursement history for a fund
(define-read-only (get-disbursement-history (fund-id uint))
  (map-get? disbursement-history { fund-id: fund-id })
)

;; Get recipient verification status
(define-read-only (get-recipient-verification (recipient principal) (fund-id uint))
  (map-get? verified-recipients { recipient: recipient, fund-id: fund-id })
)

;; Get contract statistics
(define-read-only (get-contract-stats)
  {
    total-funds-created: (var-get total-funds-created),
    total-disbursements: (var-get total-disbursements),
    total-amount-disbursed: (var-get total-amount-disbursed),
    contract-paused: (var-get contract-paused)
  }
)

;; private functions

;; Check if caller is fund manager or approver
(define-private (is-fund-manager-or-approver (fund-id uint) (caller principal))
  (let
    (
      (fund (unwrap! (map-get? fund-pools { fund-id: fund-id }) false))
      (approvers-info (unwrap! (map-get? fund-approvers { fund-id: fund-id }) false))
    )
    (or
      (is-eq caller (get fund-manager fund))
      (is-some (index-of? (get approvers approvers-info) caller))
    )
  )
)

;; Check if caller is emergency contact
(define-private (is-emergency-contact (fund-id uint) (caller principal))
  (let
    (
      (emergency-control (unwrap! (map-get? emergency-controls { fund-id: fund-id }) false))
    )
    (is-some (index-of? (get emergency-contacts emergency-control) caller))
  )
)
