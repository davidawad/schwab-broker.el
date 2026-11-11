;;; schwab-broker-ticket-test.el --- Tests for schwab-broker-ticket.el -*- lexical-binding: t; -*-

;;; Commentary:

;; Offline and pure.  The golden vectors in test/golden/tos-ticket-golden.json
;; are shared byte-for-byte with the Rust crate tos-ticket-rs
;; (tests/fixtures/golden.json).  The "site port" below re-implements, in
;; elisp and independently of schwab-broker-ticket.el, the thinkorswim web
;; code path that turns a /trade URL into a draft order (see the schema doc
;; in tos-ticket-rs: docs/tos-ticket-url-schema.md), so that
;; parse(generate(order)) == order is a real check.
;;
;; Run with:
;;   emacs -Q --batch -L . -L test -l test/schwab-broker-ticket-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(add-to-list 'load-path
             (file-name-directory
              (directory-file-name
               (file-name-directory (or load-file-name buffer-file-name)))))
(require 'schwab-broker-ticket)
(require 'schwab-broker-orders)

;; -- golden fixture ---------------------------------------------------------

(defconst schwab-broker-ticket-test--golden-file
  (expand-file-name "golden/tos-ticket-golden.json"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Path of the shared golden vectors.")

(defvar schwab-broker-ticket-test--golden nil
  "Parsed golden vectors, as a plist (loaded lazily).")

(defun schwab-broker-ticket-test--golden (key)
  "Return the golden section named by the keyword KEY."
  (unless schwab-broker-ticket-test--golden
    (setq schwab-broker-ticket-test--golden
          (with-temp-buffer
            (insert-file-contents schwab-broker-ticket-test--golden-file)
            (goto-char (point-min))
            (json-parse-buffer :object-type 'plist :array-type 'list
                               :null-object nil :false-object nil))))
  (plist-get schwab-broker-ticket-test--golden key))

(defun schwab-broker-ticket-test--order (json)
  "Convert the golden JSON order plist JSON to a ticket order plist.
Signal on any unknown key, like the Rust deserializer does."
  (let (out)
    (cl-loop for (k v) on json by #'cddr
             do (let ((key (pcase k
                             (:symbol :symbol) (:legs :legs)
                             (:order_type :order-type) (:limit :limit)
                             (:stop :stop) (:tif :tif) (:tick :tick)
                             (_ (error "Unknown order field %S" k)))))
                  (setq out (append out
                                    (list key
                                          (if (eq key :legs)
                                              (mapcar (lambda (leg)
                                                        (list :qty (plist-get leg :qty)
                                                              :instrument (plist-get leg :instrument)))
                                                      v)
                                            v))))))
    out))

(defun schwab-broker-ticket-test--cases (section)
  "Return the golden cases of SECTION as (NAME ORDER CASE) triples."
  (mapcar (lambda (c)
            (list (plist-get c :name)
                  (schwab-broker-ticket-test--order (plist-get c :order))
                  c))
          (schwab-broker-ticket-test--golden section)))

;; -- an independent port of the site's URL -> draft path ---------------------

(defun schwab-broker-ticket-test--decode (s)
  "Decode query value S like `URLSearchParams': + is a space, %XX escapes."
  (decode-coding-string (url-unhex-string (replace-regexp-in-string "+" " " s))
                        'utf-8))

(defun schwab-broker-ticket-test--params (query)
  "Return the (KEY . VALUE) pairs of QUERY in order."
  (cl-loop for kv in (split-string query "&" t)
           collect (let ((eq (cl-position ?= kv)))
                     (if eq
                         (cons (schwab-broker-ticket-test--decode (substring kv 0 eq))
                               (schwab-broker-ticket-test--decode (substring kv (1+ eq))))
                       (cons (schwab-broker-ticket-test--decode kv) "")))))

(defun schwab-broker-ticket-test--ws-replace (s with)
  "Replace each whitespace character of S with the string WITH."
  (replace-regexp-in-string "[[:space:]]" with s t t))

(defun schwab-broker-ticket-test--js-number (s)
  "Approximate JS `Number(S)' for a non-empty string; nil for NaN."
  (let ((trim (string-trim s)))
    (and (string-match-p "\\`[-+]?\\(?:[0-9]+\\.?[0-9]*\\|\\.[0-9]+\\)\\(?:[eE][-+]?[0-9]+\\)?\\'" trim)
         (float (string-to-number trim)))))

(defun schwab-broker-ticket-test--js-parse-float (s)
  "JS `parseFloat(S)': the longest numeric prefix, or nil for NaN."
  (and (string-match "\\`[[:space:]]*\\([-+]?\\(?:[0-9]+\\.?[0-9]*\\|\\.[0-9]+\\)\\(?:[eE][-+]?[0-9]+\\)?\\)" s)
       (float (string-to-number (match-string 1 s)))))

(defconst schwab-broker-ticket-test--site-types
  '("LIMIT" "MARKET" "MOC" "LOC" "STOP" "STOPLIMIT" "WALK_LIMIT")
  "orderType values the site's URL parser accepts (uS).")

(defconst schwab-broker-ticket-test--site-tifs
  '("DAY" "EXT" "EXTO" "AM" "PM" "ETH" "GTC" "GTC_EXT" "GTC_EXTO")
  "orderTif values the site's URL parser accepts (dS).")

(defun schwab-broker-ticket-test--site-draft (url)
  "Return the draft the site would build for URL, or nil for no ticket.
The result is a plist (:symbol :legs :order-type :limit :activation :tif);
each leg is (DIRECTION QTY SYMBOL), QTY nil meaning the user's default.
Ports router `_'/`y', VK, gS (TRADE case), lS, pS, uS, dS, fS, SF, jF and
the CreateDraftTrade price mapping."
  (let* ((no-frag (car (split-string url "#")))
         (qpos (cl-position ?? no-frag))
         (path (if qpos (substring no-frag 0 qpos) no-frag))
         (pairs (schwab-broker-ticket-test--params
                 (if qpos (substring no-frag (1+ qpos)) "")))
         (get (lambda (k)
                (let ((v (cdr (assoc k pairs)))) ; the last one wins (fromEntries)
                  (and v (let ((p (cl-find k (reverse pairs) :key #'car :test #'equal)))
                           (schwab-broker-ticket-test--ws-replace (cdr p) "%2B")))))))
    (when (string-suffix-p "/trade" path)
      (let* ((first (cdr (assoc "symbol" pairs))) ; searchParams.get: the first one
             (symbol (and first (schwab-broker-ticket-test--ws-replace first "+")))
             (raw (mapcar get '("leg1" "leg2" "leg3" "leg4")))
             (contiguous (let ((prev (car raw)) (ok t) (n 0))
                           (dolist (e raw)
                             (when (or (and (= n 0) (null e)) (and (null prev) e))
                               (setq ok nil))
                             (setq prev e n (1+ n)))
                           ok))
             (legs (mapcar
                    (lambda (r)
                      (let* ((parts (split-string r "," nil))
                             (qty (and (> (length parts) 1) (car parts)))
                             (sym (if (> (length parts) 1) (cadr parts) (car parts)))
                             (q (and qty (not (string-empty-p qty))
                                     (schwab-broker-ticket-test--js-number qty))))
                        (list (if (and q (< q 0)) 'sell 'buy)
                              (and q (abs q))
                              (schwab-broker-ticket-test--ws-replace sym "+"))))
                    (cl-remove-if (lambda (e) (or (null e) (string-empty-p e))) raw)))
             (type (let ((u (and (funcall get "orderType") (upcase (funcall get "orderType")))))
                     (car (member u schwab-broker-ticket-test--site-types))))
             (limit (let ((v (funcall get "limitPrice")))
                      (and v (let ((f (schwab-broker-ticket-test--js-parse-float v))) (and f (abs f))))))
             (stop (let ((v (funcall get "stopPrice")))
                     (and v (let ((f (schwab-broker-ticket-test--js-parse-float v))) (and f (abs f))))))
             (tif (let ((u (and (funcall get "orderTif") (upcase (funcall get "orderTif")))))
                    (car (member u schwab-broker-ticket-test--site-tifs))))
             (is-stop (member type '("STOP" "STOPLIMIT"))))
        (when (and symbol (not (string-empty-p symbol)) contiguous legs
                   (not (string-match-p "[*+-]" symbol)))
          (list :symbol symbol :legs legs :order-type type
                :limit (if (null limit) (and is-stop stop) limit)
                :activation (and is-stop (or stop limit))
                :tif tif))))))

(defun schwab-broker-ticket-test--expected-draft (order)
  "The draft ORDER is meant to produce, computed directly from the order."
  (let* ((type (schwab-broker-ticket--enum (plist-get order :order-type)
                                           schwab-broker-ticket-order-types "type"))
         (limit (plist-get order :limit))
         (stop (plist-get order :stop)))
    (list :symbol (or (plist-get order :symbol)
                      (let ((i (schwab-broker-ticket-parse-instrument
                                (plist-get (car (plist-get order :legs)) :instrument))))
                        (if (eq (car i) 'option) (plist-get (cdr i) :root) (cdr i))))
          :legs (mapcar (lambda (l)
                          (let ((q (plist-get l :qty)))
                            (list (if (< q 0) 'sell 'buy) (float (abs q))
                                  (schwab-broker-ticket-test--text
                                   (plist-get l :instrument)))))
                        (plist-get order :legs))
          :order-type type
          :limit (pcase type ("STOP" stop) (_ limit))
          :activation (pcase type ("STOP" stop) ("STOPLIMIT" stop) (_ nil))
          :tif (upcase (format "%s" (plist-get order :tif))))))

(defun schwab-broker-ticket-test--text (instrument)
  "TOS text for INSTRUMENT: an option converted, a plain symbol upcased."
  (schwab-broker-ticket--instrument-text
   (schwab-broker-ticket-parse-instrument instrument)))

(defun schwab-broker-ticket-test--normalize-draft (draft)
  "Return DRAFT with every number a float and the TIF/type upcased."
  (and draft
       (list :symbol (plist-get draft :symbol)
             :legs (mapcar (lambda (l) (list (nth 0 l) (and (nth 1 l) (float (nth 1 l))) (nth 2 l)))
                           (plist-get draft :legs))
             :order-type (plist-get draft :order-type)
             :limit (and (plist-get draft :limit) (float (plist-get draft :limit)))
             :activation (and (plist-get draft :activation) (float (plist-get draft :activation)))
             :tif (plist-get draft :tif))))

;; -- symbols ------------------------------------------------------------------

(ert-deftest schwab-broker-ticket-golden-symbols ()
  "Every form converts to every other form, both directions."
  (dolist (c (schwab-broker-ticket-test--golden :symbols))
    (let ((occ (plist-get c :occ)) (compact (plist-get c :compact))
          (tos (plist-get c :tos)))
      (dolist (in (list occ compact tos))
        (should (equal (schwab-broker-ticket-option-to-tos in) tos))
        (should (equal (schwab-broker-ticket-option-to-occ in) occ))
        (should (equal (schwab-broker-ticket-option-to-occ-compact in) compact)))
      (should (= (length occ) 21)))))

(ert-deftest schwab-broker-ticket-invalid-symbols ()
  (dolist (s (schwab-broker-ticket-test--golden :invalid_symbols))
    (should-error (schwab-broker-ticket-parse-option s)
                  :type 'schwab-broker-ticket-error))
  (should-error (schwab-broker-ticket-parse-option "")
                :type 'schwab-broker-ticket-error))

(ert-deftest schwab-broker-ticket-symbol-input-is-trimmed-and-case-insensitive ()
  (dolist (s '("  .nvda261113p165 " "nvda  261113p00165000" "nvda261113p00165000\n"))
    (should (equal (schwab-broker-ticket-option-to-tos s) ".NVDA261113P165"))))

(ert-deftest schwab-broker-ticket-instrument-detection ()
  (should (equal (schwab-broker-ticket-parse-instrument "nvda") '(symbol . "NVDA")))
  (should (equal (schwab-broker-ticket-parse-instrument "BRK/B") '(symbol . "BRK/B")))
  (should (eq (car (schwab-broker-ticket-parse-instrument "NVDA  261113P00165000")) 'option))
  (should (eq (car (schwab-broker-ticket-parse-instrument "NVDA261113P00165000")) 'option))
  (should (eq (car (schwab-broker-ticket-parse-instrument ".NVDA261113P165")) 'option))
  (dolist (bad '("" "NV,DA" "NV DA" ".NVDA"))
    (should-error (schwab-broker-ticket-parse-instrument bad)
                  :type 'schwab-broker-ticket-error)))

(ert-deftest schwab-broker-ticket-leap-day ()
  (should (schwab-broker-ticket-option-to-tos ".AAPL280229C200"))
  (should-error (schwab-broker-ticket-option-to-tos ".AAPL270229C200"))
  (should (schwab-broker-ticket-option-to-tos ".AAPL000229C200"))
  (should-error (schwab-broker-ticket-option-to-tos ".AAPL000230C200")))

;; -- URLs -----------------------------------------------------------------------

(ert-deftest schwab-broker-ticket-motivating-case ()
  (should (equal (schwab-broker-ticket-url
                  '(:legs ((:qty 1 :instrument ".NVDA261113P165"))
                    :order-type limit :limit 0.05 :tif gtc))
                 "https://trade.thinkorswim.com/trade?symbol=NVDA&leg1=1,.NVDA261113P165&orderType=LIMIT&limitPrice=0.05&orderTif=GTC")))

(ert-deftest schwab-broker-ticket-golden-urls ()
  (dolist (c (schwab-broker-ticket-test--cases :orders))
    (should (equal (schwab-broker-ticket-url (nth 1 c))
                   (plist-get (nth 2 c) :url)))))

(ert-deftest schwab-broker-ticket-site-parse-equals-intended-draft ()
  "parse(generate(order)) == order, through the ported site parser."
  (dolist (c (schwab-broker-ticket-test--cases :orders))
    (let* ((order (nth 1 c))
           (url (schwab-broker-ticket-url order)))
      (should (equal (schwab-broker-ticket-test--normalize-draft
                      (schwab-broker-ticket-test--site-draft url))
                     (schwab-broker-ticket-test--normalize-draft
                      (schwab-broker-ticket-test--expected-draft order)))))))

(ert-deftest schwab-broker-ticket-golden-covers-every-tif-and-shape ()
  (let ((urls (mapcar (lambda (c) (plist-get c :url))
                      (schwab-broker-ticket-test--golden :orders))))
    (dolist (tif schwab-broker-ticket-tifs)
      (should (cl-some (lambda (u) (string-suffix-p (concat "orderTif=" tif) u)) urls)))
    (dolist (ty '("LIMIT" "MARKET" "MOC" "LOC" "STOP" "STOPLIMIT"))
      (should (cl-some (lambda (u) (string-match-p (concat "orderType=" ty "&") u)) urls)))
    (should (cl-some (lambda (u) (string-match-p "leg4=" u)) urls))
    (should (cl-some (lambda (u) (string-match-p "\\.5&" u)) urls))
    (should (cl-some (lambda (u) (string-match-p "leg1=-" u)) urls))))

(ert-deftest schwab-broker-ticket-golden-summaries ()
  (let ((n 0))
    (dolist (c (schwab-broker-ticket-test--cases :orders))
      (when (plist-get (nth 2 c) :summary)
        (cl-incf n)
        (should (equal (schwab-broker-ticket-summary (nth 1 c))
                       (plist-get (nth 2 c) :summary)))))
    (should (>= n 10))))

(ert-deftest schwab-broker-ticket-motivating-summary ()
  (should (equal (schwab-broker-ticket-summary
                  '(:legs ((:qty 1 :instrument "NVDA  261113P00165000"))
                    :order-type "limit" :limit 0.05 :tif "gtc"))
                 "BUY 1 NVDA 13 Nov 26 165 PUT, LIMIT 0.05, GTC")))

(ert-deftest schwab-broker-ticket-encoding ()
  (should (equal (schwab-broker-ticket--encode "1,.NVDA261113P165") "1,.NVDA261113P165"))
  (should (equal (schwab-broker-ticket--encode "A+B C") "A%2BB%20C"))
  (should (equal (schwab-broker-ticket--encode "/ES") "%2FES"))
  (should (equal (schwab-broker-ticket--encode "$SPX") "%24SPX"))
  (should (equal (schwab-broker-ticket--encode "a&b=c#d%") "a%26b%3Dc%23d%25"))
  (should (equal (schwab-broker-ticket--encode "é") "%C3%A9")))

(ert-deftest schwab-broker-ticket-price-formatting ()
  (should (equal (schwab-broker-ticket--format-price 0.05) "0.05"))
  (should (equal (schwab-broker-ticket--format-price 1.0) "1"))
  (should (equal (schwab-broker-ticket--format-price 180) "180"))
  (should (equal (schwab-broker-ticket--format-price 450.5) "450.5"))
  (should (equal (schwab-broker-ticket--format-price 1.0e-7) "0.0000001"))
  (should (equal (schwab-broker-ticket--format-price 1.5e-7) "0.00000015"))
  (should (equal (schwab-broker-ticket--format-price 1.0e10) "10000000000")))

;; -- validation: refuse, never guess ----------------------------------------

(ert-deftest schwab-broker-ticket-golden-valid-orders-have-no-violations ()
  (dolist (c (schwab-broker-ticket-test--cases :orders))
    (should (null (schwab-broker-ticket-violations (nth 1 c))))))

(ert-deftest schwab-broker-ticket-golden-invalid-orders ()
  (dolist (c (schwab-broker-ticket-test--cases :invalid_orders))
    (should (equal (mapcar #'symbol-name
                           (schwab-broker-ticket-violations (nth 1 c)))
                   (plist-get (nth 2 c) :kinds)))
    (should-error (schwab-broker-ticket-url (nth 1 c))
                  :type 'schwab-broker-ticket-error)))

(ert-deftest schwab-broker-ticket-invalid-json-inputs-are-refused ()
  "Fractional or string quantity, unknown enums, bad dates, unknown keys."
  (dolist (c (schwab-broker-ticket-test--golden :invalid_json))
    (should-error
     (schwab-broker-ticket-url (schwab-broker-ticket-test--order (plist-get c :order)))
     :type 'error)))

(ert-deftest schwab-broker-ticket-nothing-is-defaulted ()
  (let ((base '(:legs ((:qty 1 :instrument "NVDA")) :order-type market :tif day)))
    (should (null (schwab-broker-ticket-violations base)))
    (should (equal (schwab-broker-ticket-violations
                    (plist-put (copy-sequence base) :order-type nil))
                   '(missing_order_type)))
    (should (equal (schwab-broker-ticket-violations
                    (plist-put (copy-sequence base) :tif nil))
                   '(missing_tif)))))

(ert-deftest schwab-broker-ticket-nonfinite-prices ()
  (dolist (p (list 0.0e+NaN 1.0e+INF -1.0e+INF))
    (should (equal (schwab-broker-ticket-violations
                    `(:legs ((:qty 1 :instrument "NVDA")) :order-type limit
                      :tif day :limit ,p))
                   '(bad_price)))))

(ert-deftest schwab-broker-ticket-leg-count-boundary ()
  (cl-flet ((order (n)
              `(:legs ,(cl-loop for i below n
                                collect (list :qty 1 :instrument (format ".SPY261113P%d" (+ 400 i))))
                :order-type market :tif day)))
    (should (null (schwab-broker-ticket-violations (order 4))))
    (should (equal (schwab-broker-ticket-violations (order 5)) '(too_many_legs)))))

(ert-deftest schwab-broker-ticket-closing-legs ()
  (dolist (c (schwab-broker-ticket-test--golden :closing))
    (let* ((inst (plist-get c :instrument))
           (symbol (schwab-broker-ticket-test--text inst))
           (pos (let ((q (plist-get c :position_qty)))
                  `((longQuantity . ,(max q 0)) (shortQuantity . ,(max (- q) 0))
                    (instrument . ((symbol . ,inst)
                                   (assetType . ,(if (string-prefix-p "." symbol) "OPTION" "EQUITY")))))))
           (order (schwab-broker-ticket-for-position pos :order-type 'market :tif 'day)))
      (should (= (plist-get (car (plist-get order :legs)) :qty) (plist-get c :leg_qty))))))

(ert-deftest schwab-broker-ticket-for-position-short-put-buys-one ()
  (let ((order (schwab-broker-ticket-for-position
                '((longQuantity . 0) (shortQuantity . 1) (marketValue . -104.0)
                  (instrument . ((assetType . "OPTION") (symbol . "NVDA  261113P00165000"))))
                :order-type "LIMIT" :limit 0.05 :tif "GTC")))
    (should (equal (schwab-broker-ticket-url order)
                   "https://trade.thinkorswim.com/trade?symbol=NVDA&leg1=1,.NVDA261113P165&orderType=LIMIT&limitPrice=0.05&orderTif=GTC"))))

(ert-deftest schwab-broker-ticket-for-position-refusals ()
  (should-error (schwab-broker-ticket-for-position
                 '((longQuantity . 0) (shortQuantity . 0)
                   (instrument . ((assetType . "EQUITY") (symbol . "NVDA")))))
                :type 'schwab-broker-ticket-error)
  (should-error (schwab-broker-ticket-for-position
                 '((longQuantity . 1.5) (shortQuantity . 0)
                   (instrument . ((assetType . "EQUITY") (symbol . "NVDA")))))
                :type 'schwab-broker-ticket-error)
  (should-error (schwab-broker-ticket-for-position
                 '((longQuantity . 1) (shortQuantity . 0)
                   (instrument . ((assetType . "FIXED_INCOME") (symbol . "912828")))))
                :type 'schwab-broker-ticket-error))

(ert-deftest schwab-broker-ticket-from-order-spec ()
  (let* ((spec (schwab-broker-order-option-limit "NVDA  261113P00165000" "BUY_TO_CLOSE" 1 0.05))
         (spec (cons '(duration . "GOOD_TILL_CANCEL") (assq-delete-all 'duration spec)))
         (order (schwab-broker-ticket-from-order-spec spec)))
    (should (equal (schwab-broker-ticket-url order)
                   "https://trade.thinkorswim.com/trade?symbol=NVDA&leg1=1,.NVDA261113P165&orderType=LIMIT&limitPrice=0.05&orderTif=GTC")))
  (let ((order (schwab-broker-ticket-from-order-spec
                (schwab-broker-order-equity-stop-limit "NVDA" "SELL" 100 100 99.5))))
    (should (equal (schwab-broker-ticket-violations order) nil))
    (should (string-match-p "orderType=STOPLIMIT&limitPrice=99.5&stopPrice=100&orderTif=DAY"
                            (schwab-broker-ticket-url order))))
  (should-error (schwab-broker-ticket-from-order-spec
                 (schwab-broker-order-equity-market "NVDA" "HOLD" 1))
                :type 'schwab-broker-ticket-error))

;; -- the site port itself (pins the behavior the refusals rely on) ----------

(ert-deftest schwab-broker-ticket-site-port-quirks ()
  (cl-flet ((d (extra) (schwab-broker-ticket-test--site-draft
                        (concat "https://trade.thinkorswim.com/trade?symbol=NVDA&leg1=1,NVDA" extra))))
    (should (null (plist-get (d "&orderType=MKT") :order-type)))
    (should (null (plist-get (d "&orderType=TRAILSTOP") :order-type)))
    (should (null (plist-get (d "&orderTif=FOREVER") :tif)))
    (should (null (plist-get (d "") :order-type)))
    (should (equal (plist-get (d "&orderType=limit&limitPrice=1&orderTif=gtc") :order-type) "LIMIT"))
    (should (= (plist-get (d "&orderType=LIMIT&limitPrice=-0.05") :limit) 0.05))
    (should (= (plist-get (d "&orderType=LIMIT&limitPrice=0.05abc") :limit) 0.05))
    (should (null (plist-get (d "&orderType=LIMIT&limitPrice=abc") :limit)))
    (let ((s (d "&orderType=STOP&limitPrice=5")))
      (should (= (plist-get s :limit) 5.0))
      (should (= (plist-get s :activation) 5.0)))
    (let ((s (d "&orderType=LIMIT&stopPrice=5")))
      (should (null (plist-get s :limit)))
      (should (null (plist-get s :activation)))))
  (cl-flet ((leg (v) (car (plist-get (schwab-broker-ticket-test--site-draft
                                      (concat "https://trade.thinkorswim.com/trade?symbol=NVDA&leg1=" v))
                                     :legs))))
    (should (equal (leg "0,NVDA") '(buy 0.0 "NVDA")))
    (should (equal (leg "x,NVDA") '(buy nil "NVDA")))
    (should (equal (leg "NVDA") '(buy nil "NVDA")))
    (should (equal (leg "-1,NVDA") '(sell 1.0 "NVDA"))))
  (should (null (schwab-broker-ticket-test--site-draft
                 "https://trade.thinkorswim.com/trade?symbol=BRK-B&leg1=1,BRKB")))
  (should (null (schwab-broker-ticket-test--site-draft
                 "https://trade.thinkorswim.com/trade?symbol=NVDA&leg2=1,NVDA")))
  (should (null (schwab-broker-ticket-test--site-draft
                 "https://trade.thinkorswim.com/trade?symbol=NVDA&leg1=1,NVDA&leg3=1,NVDA"))))

;; -- interactive entry points (mocked; nothing is opened) --------------------

(ert-deftest schwab-broker-ticket-open-calls-browse-url-with-the-url ()
  (let (opened)
    (cl-letf (((symbol-function 'browse-url) (lambda (u &rest _) (setq opened u))))
      (let ((url (schwab-broker-ticket-open
                  '(:legs ((:qty 1 :instrument ".NVDA261113P165"))
                    :order-type limit :limit 0.05 :tif gtc))))
        (should (equal opened url))
        (should (string-prefix-p "https://trade.thinkorswim.com/trade?" opened))))))

(ert-deftest schwab-broker-ticket-open-refuses-an-invalid-order-without-browsing ()
  (let (opened)
    (cl-letf (((symbol-function 'browse-url) (lambda (u &rest _) (setq opened u))))
      (should-error (schwab-broker-ticket-open
                     '(:legs ((:qty 0 :instrument "NVDA")) :order-type market :tif day))
                    :type 'schwab-broker-ticket-error)
      (should (null opened)))))

(ert-deftest schwab-broker-ticket-url-copies-to-kill-ring ()
  (let ((kill-ring nil))
    (let ((url (schwab-broker-ticket-url
                '(:legs ((:qty 1 :instrument "NVDA")) :order-type market :tif day) t)))
      (should (equal (car kill-ring) url)))))

(ert-deftest schwab-broker-ticket-interactive-prompts ()
  (let ((answers (list "1,.NVDA261113P165" "")) opened)
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) (pop answers)))
              ((symbol-function 'completing-read)
               (lambda (prompt &rest _) (if (string-match-p "Order" prompt) "LIMIT" "GTC")))
              ((symbol-function 'read-number) (lambda (&rest _) 0.05))
              ((symbol-function 'browse-url) (lambda (u &rest _) (setq opened u))))
      (call-interactively #'schwab-broker-ticket-open)
      (should (equal opened "https://trade.thinkorswim.com/trade?symbol=NVDA&leg1=1,.NVDA261113P165&orderType=LIMIT&limitPrice=0.05&orderTif=GTC")))))

(ert-deftest schwab-broker-ticket-close-position-opens-the-closing-ticket ()
  (let (opened)
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "GTC"))
              ((symbol-function 'read-number) (lambda (&rest _) 0.05))
              ((symbol-function 'browse-url) (lambda (u &rest _) (setq opened u))))
      (schwab-broker-ticket-close-position
       '((longQuantity . 0) (shortQuantity . 1)
         (instrument . ((assetType . "OPTION") (symbol . "NVDA  261113P00165000")))))
      (should (equal opened "https://trade.thinkorswim.com/trade?symbol=NVDA&leg1=1,.NVDA261113P165&orderType=LIMIT&limitPrice=0.05&orderTif=GTC")))))

(provide 'schwab-broker-ticket-test)
;;; schwab-broker-ticket-test.el ends here
