;; title: scholarship-registry
;; version: 1.0.0
;; summary: Smart contract to list scholarships and eligibility criteria
;; description: A comprehensive system for managing scholarship registrations,
;; applications, and eligibility verification on the blockchain

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
(define-constant ERR_APPLICATION_CLOSED (err u403))
(define-constant ERR_NOT_ELIGIBLE (err u405))

;; Application status constants
(define-constant STATUS_PENDING u1)
(define-constant STATUS_APPROVED u2)
(define-constant STATUS_REJECTED u3)
(define-constant STATUS_FUNDED u4)

;; Academic level constants
(define-constant LEVEL_UNDERGRADUATE u1)
(define-constant LEVEL_GRADUATE u2)
(define-constant LEVEL_DOCTORAL u3)
(define-constant LEVEL_POSTDOC u4)

;; data vars
(define-data-var next-scholarship-id uint u1)
(define-data-var next-application-id uint u1)
(define-data-var contract-paused bool false)
(define-data-var total-scholarships uint u0)
(define-data-var total-applications uint u0)

;; data maps
;; Scholarship registry with comprehensive details
(define-map scholarships
  { scholarship-id: uint }
  {
    title: (string-ascii 100),
    description: (string-ascii 500),
    provider: principal,
    amount: uint,
    academic-level: uint,
    field-of-study: (string-ascii 50),
    min-gpa: uint, ;; GPA * 100 (e.g., 350 = 3.50 GPA)
    max-age: uint,
    deadline: uint, ;; Block height
    is-active: bool,
    total-recipients: uint,
    remaining-slots: uint,
    created-at: uint
  }
)

;; Application tracking
(define-map applications
  { application-id: uint }
  {
    scholarship-id: uint,
    applicant: principal,
    gpa: uint, ;; GPA * 100
    age: uint,
    field-of-study: (string-ascii 50),
    personal-statement: (string-ascii 1000),
    status: uint,
    applied-at: uint,
    reviewed-at: (optional uint),
    reviewer: (optional principal)
  }
)

;; Track applications by scholarship for efficiency
(define-map scholarship-applications
  { scholarship-id: uint }
  { application-ids: (list 100 uint), count: uint }
)

;; Track applications by user
(define-map user-applications
  { user: principal }
  { application-ids: (list 50 uint), count: uint }
)

;; Admin permissions
(define-map admins
  { admin: principal }
  { is-admin: bool, added-at: uint }
)

;; Scholarship categories for organization
(define-map scholarship-categories
  { category: (string-ascii 50) }
  { scholarship-ids: (list 100 uint), count: uint }
)

;; public functions

;; Register a new scholarship program
(define-public (register-scholarship
  (title (string-ascii 100))
  (description (string-ascii 500))
  (amount uint)
  (academic-level uint)
  (field-of-study (string-ascii 50))
  (min-gpa uint)
  (max-age uint)
  (deadline uint)
  (total-recipients uint)
)
  (let
    (
      (scholarship-id (var-get next-scholarship-id))
      (current-block stacks-block-height)
    )
    (asserts! (not (var-get contract-paused)) ERR_UNAUTHORIZED)
    (asserts! (> (len title) u0) ERR_INVALID_PARAMS)
    (asserts! (> amount u0) ERR_INVALID_PARAMS)
    (asserts! (and (>= academic-level LEVEL_UNDERGRADUATE) (<= academic-level LEVEL_POSTDOC)) ERR_INVALID_PARAMS)
    (asserts! (> deadline current-block) ERR_INVALID_PARAMS)
    (asserts! (> total-recipients u0) ERR_INVALID_PARAMS)
    (asserts! (and (>= min-gpa u0) (<= min-gpa u400)) ERR_INVALID_PARAMS) ;; 0.0 to 4.0 GPA
    
    ;; Create scholarship entry
    (map-set scholarships
      { scholarship-id: scholarship-id }
      {
        title: title,
        description: description,
        provider: tx-sender,
        amount: amount,
        academic-level: academic-level,
        field-of-study: field-of-study,
        min-gpa: min-gpa,
        max-age: max-age,
        deadline: deadline,
        is-active: true,
        total-recipients: total-recipients,
        remaining-slots: total-recipients,
        created-at: current-block
      }
    )
    
    ;; Initialize scholarship applications tracker
    (map-set scholarship-applications
      { scholarship-id: scholarship-id }
      { application-ids: (list), count: u0 }
    )
    
    ;; Update category mapping
    (add-to-category field-of-study scholarship-id)
    
    ;; Update counters
    (var-set next-scholarship-id (+ scholarship-id u1))
    (var-set total-scholarships (+ (var-get total-scholarships) u1))
    
    (ok scholarship-id)
  )
)

;; Apply for a scholarship
(define-public (apply-for-scholarship
  (scholarship-id uint)
  (gpa uint)
  (age uint)
  (field-of-study (string-ascii 50))
  (personal-statement (string-ascii 1000))
)
  (let
    (
      (application-id (var-get next-application-id))
      (scholarship (unwrap! (map-get? scholarships { scholarship-id: scholarship-id }) ERR_NOT_FOUND))
      (current-block stacks-block-height)
      (user-apps (default-to { application-ids: (list), count: u0 }
                    (map-get? user-applications { user: tx-sender })))
      (scholarship-apps (default-to { application-ids: (list), count: u0 }
                          (map-get? scholarship-applications { scholarship-id: scholarship-id })))
    )
    (asserts! (not (var-get contract-paused)) ERR_UNAUTHORIZED)
    (asserts! (get is-active scholarship) ERR_APPLICATION_CLOSED)
    (asserts! (< current-block (get deadline scholarship)) ERR_APPLICATION_CLOSED)
    (asserts! (> (get remaining-slots scholarship) u0) ERR_APPLICATION_CLOSED)
    (asserts! (>= gpa (get min-gpa scholarship)) ERR_NOT_ELIGIBLE)
    (asserts! (<= age (get max-age scholarship)) ERR_NOT_ELIGIBLE)
    (asserts! (< (get count user-apps) u50) ERR_INVALID_PARAMS) ;; Limit applications per user
    
    ;; Create application
    (map-set applications
      { application-id: application-id }
      {
        scholarship-id: scholarship-id,
        applicant: tx-sender,
        gpa: gpa,
        age: age,
        field-of-study: field-of-study,
        personal-statement: personal-statement,
        status: STATUS_PENDING,
        applied-at: current-block,
        reviewed-at: none,
        reviewer: none
      }
    )
    
    ;; Update user applications tracking
    (map-set user-applications
      { user: tx-sender }
      {
        application-ids: (unwrap! (as-max-len? (append (get application-ids user-apps) application-id) u50) ERR_INVALID_PARAMS),
        count: (+ (get count user-apps) u1)
      }
    )
    
    ;; Update scholarship applications tracking
    (map-set scholarship-applications
      { scholarship-id: scholarship-id }
      {
        application-ids: (unwrap! (as-max-len? (append (get application-ids scholarship-apps) application-id) u100) ERR_INVALID_PARAMS),
        count: (+ (get count scholarship-apps) u1)
      }
    )
    
    ;; Update counters
    (var-set next-application-id (+ application-id u1))
    (var-set total-applications (+ (var-get total-applications) u1))
    
    (ok application-id)
  )
)

;; read only functions

;; Get scholarship details
(define-read-only (get-scholarship-details (scholarship-id uint))
  (map-get? scholarships { scholarship-id: scholarship-id })
)

;; Get application details
(define-read-only (get-application-details (application-id uint))
  (map-get? applications { application-id: application-id })
)

;; Check if user meets scholarship eligibility
(define-read-only (check-eligibility
  (scholarship-id uint)
  (gpa uint)
  (age uint)
)
  (match (map-get? scholarships { scholarship-id: scholarship-id })
    scholarship (ok (and
      (get is-active scholarship)
      (> (get remaining-slots scholarship) u0)
      (> (get deadline scholarship) stacks-block-height)
      (>= gpa (get min-gpa scholarship))
      (<= age (get max-age scholarship))
    ))
    ERR_NOT_FOUND
  )
)

;; Get user's applications
(define-read-only (get-user-applications (user principal))
  (map-get? user-applications { user: user })
)

;; Get scholarship applications
(define-read-only (get-scholarship-applications (scholarship-id uint))
  (map-get? scholarship-applications { scholarship-id: scholarship-id })
)

;; Get contract statistics
(define-read-only (get-contract-stats)
  {
    total-scholarships: (var-get total-scholarships),
    total-applications: (var-get total-applications),
    contract-paused: (var-get contract-paused)
  }
)

;; private functions

;; Add scholarship to category
(define-private (add-to-category (category (string-ascii 50)) (scholarship-id uint))
  (let
    (
      (current-category (default-to { scholarship-ids: (list), count: u0 }
                          (map-get? scholarship-categories { category: category })))
    )
    (map-set scholarship-categories
      { category: category }
      {
        scholarship-ids: (unwrap! (as-max-len? (append (get scholarship-ids current-category) scholarship-id) u100) false),
        count: (+ (get count current-category) u1)
      }
    )
  )
)
