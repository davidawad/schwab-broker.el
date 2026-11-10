;;; schwab-broker-margin-test.el --- Tests for schwab-broker-margin.el -*- lexical-binding: t; -*-

;;; Commentary:

;; Offline, pure.  Vectors come from the CBOE "Margin Requirement
;; Examples" PDF (AAPL close 127.83 on 2021-01-19; the CBOE figures are
;; NET of option credit) and Schwab's published tables.  See
;; docs/margin.md.

;;; Code:

(require 'ert)
(require 'cl-lib)
(add-to-list 'load-path (file-name-directory (directory-file-name (file-name-directory (or load-file-name buffer-file-name)))))
(require 'schwab-broker-margin)

(defun schwab-broker-margin-test--near (a b &optional tol)
  "Non-nil when A and B differ by at most TOL (default 0.01)."
  (<= (abs (- a b)) (or tol 0.01)))

(ert-deftest schwab-broker-margin-short-put-cboe-aapl ()
  "CBOE: short 100 AAPL Mar 130 puts @ 8.94 -> $255,660 (net)."
  (let ((r (schwab-broker-margin-short-put :strike 130 :premium 8.94
                                           :underlying 127.83 :qty 100)))
    (should (schwab-broker-margin-test--near (plist-get r :net) 255660.0 0.5))
    (should (schwab-broker-margin-test--near (plist-get r :gross) 345060.0 0.5))))

(ert-deftest schwab-broker-margin-short-call-cboe-aapl ()
  "CBOE: short 100 AAPL Mar 130 calls @ 6.65 -> $233,960 (net)."
  (let ((r (schwab-broker-margin-short-call :strike 130 :premium 6.65
                                            :underlying 127.83 :qty 100)))
    (should (schwab-broker-margin-test--near (plist-get r :net) 233960.0 0.5))))

(ert-deftest schwab-broker-margin-short-put-otm-nvda ()
  "Research note: NVDA 175.99, Nov13 170P @2.97 -> gross 3,217.8, net 2,920.8."
  (let ((r (schwab-broker-margin-short-put :strike 170 :premium 2.97
                                           :underlying 175.99)))
    (should (schwab-broker-margin-test--near (plist-get r :leg-pct) 3217.8))
    (should (schwab-broker-margin-test--near (plist-get r :leg-min) 1997.0))
    (should (schwab-broker-margin-test--near (plist-get r :gross) 3217.8))
    (should (schwab-broker-margin-test--near (plist-get r :net) 2920.8))))

(ert-deftest schwab-broker-margin-short-put-min-leg-binds ()
  "Deep OTM: the 10%-of-strike leg binds."
  (let ((r (schwab-broker-margin-short-put :strike 50 :premium 0.10
                                           :underlying 100)))
    (should (schwab-broker-margin-test--near (plist-get r :gross) 510.0))))

(provide 'schwab-broker-margin-test)
;;; schwab-broker-margin-test.el ends here
