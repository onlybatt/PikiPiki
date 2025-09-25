;; ---------------------------------------------------
;; Mini Prediction Market Contract (Clean Version)
;; ---------------------------------------------------

;; Data variables
(define-data-var market-id uint u0)

;; Data maps
(define-map markets 
  {id: uint} 
  {end: uint, settled: bool, outcome: bool})

(define-map pool 
  {id: uint} 
  {yes: uint, no: uint})

(define-map yes-shares 
  {id: uint, who: principal} 
  {amt: uint})

(define-map no-shares 
  {id: uint, who: principal} 
  {amt: uint})

;; Error constants
(define-constant ERR-MARKET-EXPIRED u100)
(define-constant ERR-MARKET-ALREADY-SETTLED u101)
(define-constant ERR-MARKET-NOT-SETTLED u102)
(define-constant ERR-NO-SHARES u103)
(define-constant ERR-MARKET-NOT-FOUND u104)
(define-constant ERR-TRANSFER-FAILED u105)
(define-constant ERR-INVALID-AMOUNT u106)
(define-constant ERR-MARKET-NOT-EXPIRED u107)
(define-constant ERR-INVALID-DURATION u108)
(define-constant ERR-INVALID-MARKET-ID u109)

;; Constants for validation
(define-constant MAX-DURATION u144000) ;; ~100 days in blocks
(define-constant MIN-DURATION u144) ;; ~1 day in blocks
(define-constant MAX-MARKET-ID u1000000)

;; Create a new prediction market
(define-public (create (duration uint))
  (begin
    ;; Validate duration input
    (asserts! (and (>= duration MIN-DURATION) (<= duration MAX-DURATION)) (err ERR-INVALID-DURATION))
    
    (let ((id (+ (var-get market-id) u1)))
      ;; Validate market ID doesn't overflow
      (asserts! (<= id MAX-MARKET-ID) (err ERR-INVALID-MARKET-ID))
      
      (var-set market-id id)
      (map-set markets {id: id} 
        {end: (+ stacks-block-height duration), settled: false, outcome: false})
      (map-set pool {id: id} {yes: u0, no: u0})
      (ok id))))

;; Private function to handle buying shares
(define-private (buy* (id uint) (amt uint) (side bool))
  (begin
    ;; Validate inputs
    (asserts! (> id u0) (err ERR-INVALID-MARKET-ID))
    (asserts! (<= id MAX-MARKET-ID) (err ERR-INVALID-MARKET-ID))
    (asserts! (> amt u0) (err ERR-INVALID-AMOUNT))
    
    (let ((market-data (map-get? markets {id: id})))
      (match market-data
        market (begin
          ;; Check if market exists and hasn't expired
          (asserts! (< stacks-block-height (get end market)) (err ERR-MARKET-EXPIRED))
          
          ;; Transfer STX to contract
          (match (stx-transfer? amt tx-sender (as-contract tx-sender))
            success (begin
              ;; Update pool
              (let ((pool-data (default-to {yes: u0, no: u0} (map-get? pool {id: id}))))
                (map-set pool {id: id}
                  {yes: (if side (+ (get yes pool-data) amt) (get yes pool-data)),
                   no: (if side (get no pool-data) (+ (get no pool-data) amt))})
                
                ;; Update user shares
                (if side
                  (let ((current-shares (default-to {amt: u0} 
                          (map-get? yes-shares {id: id, who: tx-sender}))))
                    (map-set yes-shares {id: id, who: tx-sender} 
                      {amt: (+ (get amt current-shares) amt)})
                    (ok true))
                  (let ((current-shares (default-to {amt: u0} 
                          (map-get? no-shares {id: id, who: tx-sender}))))
                    (map-set no-shares {id: id, who: tx-sender} 
                      {amt: (+ (get amt current-shares) amt)})
                    (ok true)))))
            error (err ERR-TRANSFER-FAILED)))
        (err ERR-MARKET-NOT-FOUND)))))

;; Buy YES shares
(define-public (buy-yes (id uint) (amt uint))
  (buy* id amt true))

;; Buy NO shares
(define-public (buy-no (id uint) (amt uint))
  (buy* id amt false))

;; Settle a market (should be called by oracle or admin)
(define-public (settle (id uint) (outcome bool))
  (begin
    ;; Validate inputs
    (asserts! (> id u0) (err ERR-INVALID-MARKET-ID))
    (asserts! (<= id MAX-MARKET-ID) (err ERR-INVALID-MARKET-ID))
    
    (let ((market-data (map-get? markets {id: id})))
      (match market-data
        market (begin
          ;; Check if market exists, hasn't been settled, and has expired
          (asserts! (not (get settled market)) (err ERR-MARKET-ALREADY-SETTLED))
          (asserts! (>= stacks-block-height (get end market)) (err ERR-MARKET-NOT-EXPIRED))
          
          (map-set markets {id: id} 
            {end: (get end market), settled: true, outcome: outcome})
          (ok true))
        (err ERR-MARKET-NOT-FOUND)))))

;; Redeem winnings
(define-public (redeem (id uint))
  (begin
    ;; Validate inputs
    (asserts! (> id u0) (err ERR-INVALID-MARKET-ID))
    (asserts! (<= id MAX-MARKET-ID) (err ERR-INVALID-MARKET-ID))
    
    (let ((market-data (map-get? markets {id: id}))
          (pool-data (map-get? pool {id: id})))
      (match market-data
        market (match pool-data
          pool-info (begin
            ;; Check if market is settled
            (asserts! (get settled market) (err ERR-MARKET-NOT-SETTLED))
            
            (if (get outcome market) ;; YES won
              (let ((user-shares (default-to {amt: u0} 
                      (map-get? yes-shares {id: id, who: tx-sender}))))
                (asserts! (> (get amt user-shares) u0) (err ERR-NO-SHARES))
                (asserts! (> (get yes pool-info) u0) (err ERR-NO-SHARES)) ;; Prevent division by zero
                
                (let ((total-pool (+ (get yes pool-info) (get no pool-info)))
                      (payout (/ (* (get amt user-shares) total-pool) (get yes pool-info))))
                  (map-delete yes-shares {id: id, who: tx-sender})
                  (match (as-contract (stx-transfer? payout tx-sender tx-sender))
                    success (ok payout)
                    error (err ERR-TRANSFER-FAILED))))
              
              ;; NO won
              (let ((user-shares (default-to {amt: u0} 
                      (map-get? no-shares {id: id, who: tx-sender}))))
                (asserts! (> (get amt user-shares) u0) (err ERR-NO-SHARES))
                (asserts! (> (get no pool-info) u0) (err ERR-NO-SHARES)) ;; Prevent division by zero
                
                (let ((total-pool (+ (get yes pool-info) (get no pool-info)))
                      (payout (/ (* (get amt user-shares) total-pool) (get no pool-info))))
                  (map-delete no-shares {id: id, who: tx-sender})
                  (match (as-contract (stx-transfer? payout tx-sender tx-sender))
                    success (ok payout)
                    error (err ERR-TRANSFER-FAILED))))))
          (err ERR-MARKET-NOT-FOUND))
        (err ERR-MARKET-NOT-FOUND)))))

;; Read-only functions for querying state

(define-read-only (get-market (id uint))
  (if (and (> id u0) (<= id MAX-MARKET-ID))
    (map-get? markets {id: id})
    none))

(define-read-only (get-pool (id uint))
  (if (and (> id u0) (<= id MAX-MARKET-ID))
    (map-get? pool {id: id})
    none))

(define-read-only (get-yes-shares (id uint) (who principal))
  (if (and (> id u0) (<= id MAX-MARKET-ID))
    (map-get? yes-shares {id: id, who: who})
    none))

(define-read-only (get-no-shares (id uint) (who principal))
  (if (and (> id u0) (<= id MAX-MARKET-ID))
    (map-get? no-shares {id: id, who: who})
    none))

(define-read-only (get-current-market-id)
  (var-get market-id))

;; Get market price (YES probability based on pool ratio)
(define-read-only (get-market-price (id uint))
  (if (and (> id u0) (<= id MAX-MARKET-ID))
    (match (map-get? pool {id: id})
      pool-data (let ((total (+ (get yes pool-data) (get no pool-data))))
                  (if (> total u0)
                    (some (/ (* (get yes pool-data) u100) total))
                    (some u50))) ;; Default to 50% if no trades
      none)
    none))