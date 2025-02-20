;;; xpra.el --- Making frames through xpra           -*- lexical-binding: t; -*-

;; Copyright (C) 2025  

;; Author: Spencer Baugh <sbaugh@catern.com>
;; Keywords: frames

;;; Commentary:

;; 

;;; Code:
(require 'comint)

(defcustom xpra-exe "/nix/store/ng20vsrvai62dsy87b41filsqs6j69z4-xpra-6.2.2/bin/xpra"
  "The xpra executable.")

(defcustom xpra-additional-args
  '("--printing=no" "--webcam=no" "--mdns=no" "--pulseaudio=no" "--opengl=no"
    "--source=/dev/null" "--splash=no" "--http-scripts=all")
  "Additional args passed to xpra.")

(defcustom xpra-idle-timeout 30
  "Idle timeout for the xpra frames.

Set to 0 to disable.")

(defvar xpra-buffer-name "*xpra server %s*"
  "Name for xpra buffers, with %s substituted for port number.")

(defvar xpra-ssl-key nil
  "Filename of SSL key to use with xpra.

If nil, use self-signed certs.")

(defvar xpra-ssl-cert nil
  "Filename of SSL cert to use with xpra.

If nil, use self-signed certs.")

(require 'bindat)

(defvar xpra-password-bindat-spec
  (bindat-type
    (r0 sint 32 t)
    (r1 sint 32 t)
    (r2 sint 32 t)
    (r3 sint 32 t)))

(defun xpra--make-password ()
  (base64url-encode-string
   (bindat-pack xpra-password-bindat-spec
		`((r0 . ,(random t)) (r1 . ,(random t)) (r2 . ,(random t)) (r3 . ,(random t))))
   t))

(defun xpra-start (&optional interactive)
  (interactive "p")
  (with-current-buffer (get-buffer-create (format xpra-buffer-name "new"))
    (while-let ((proc (get-buffer-process (current-buffer))))
      (kill-process proc))
    (comint-mode)
    (erase-buffer)
    (insert "xpra server logs:\n")
    (let ((dir (locate-user-emacs-file "xpra")))
      (make-directory dir t)
      (set-file-modes dir #o700)
      (setq default-directory dir))
    (let* ((fqdn (string-trim (shell-command-to-string "hostname --fqdn")))
	   (process-environment
	    (append '("XPRA_EXPORT_MENU_DATA=false"
		      ;; Suppress the `server-create-dumb-terminal-frame' (buggy) behavior.
		      "TERM=notdumb")
		    process-environment))
	   (processing-from (point))
	   (password (xpra--make-password))
	   ssl-key ssl-cert
	   proc
	   port)
      (if (or xpra-ssl-key xpra-ssl-cert)
	  (setq ssl-key xpra-ssl-key ssl-cert xpra-ssl-cert)
	(setq ssl-key (expand-file-name "key.pem") ssl-cert (expand-file-name "cert.pem"))
	(unless (file-exists-p ssl-key)
	  (message "Generating self-signed certs.")
	  (shell-command
	   (concat
	    "openssl req -x509 -newkey rsa:4096 -keyout " ssl-key " -out " ssl-cert " -sha256 -days 3650 -nodes -subj /C=US/CN=" fqdn))))
      (cl-assert (file-exists-p ssl-key))
      (cl-assert (file-exists-p ssl-cert))
      (setq proc (make-process
		  :name "xpra"
		  :buffer (current-buffer)
		  :command
		  `(,xpra-exe
		    "start"
		    ,@xpra-additional-args
		    "--daemon=no"
		    ,(format "--bind-wss=0:0,auth=password,value=%s" password)
		    ,(format "--server-idle-timeout=%s" xpra-idle-timeout)
		    ,(format "--ssl-key=%s" ssl-key)
		    ,(format "--ssl-cert=%s" ssl-cert)
		    ,(format "--socket-dirs=%s" default-directory)
		    "--exit-with-children" "--terminate-children=yes"
		    "--start-child=emacsclient --frame-parameters='((fullscreen . fullboth))' --create-frame"
		    "--html=/home/sbaugh/src/xpra-html5/html5")
		  :connection-type 'pipe
		  :noquery t))
      (while (and (null port) (accept-process-output proc))
	(unless (process-live-p proc)
	  (error "Xpra aborted"))
	(goto-char processing-from)
	(when (re-search-forward (rx "allocated " (+ nonl) " port " (group (+ digit)) " on ") nil 'noerror)
	  (setq port (string-to-number (match-string 1))))
	(setq processing-from (point)))
      (let ((name (format xpra-buffer-name port)))
	;; Ports can be reused.
	(when (get-buffer name)
	  (kill-buffer name))
	(rename-buffer name))
      (let (;; offscreen=no because of https://github.com/Xpra-org/xpra-html5/issues/329
	    (s (format "https://%s:%s/?emacs&password=%s&floating_menu=no&offscreen=no" fqdn port password)))
	(when interactive
	  (message "Frame on %s" s)
	  (kill-new s))
	s))))

(provide 'xpra)
;;; xpra.el ends here
