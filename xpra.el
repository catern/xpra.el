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

(defcustom xpra-nginx-exe "nginx"
  "The nginx executable.")

(defvar xpra-nginx-buffer-name "*xpra nginx*"
  "Name for the xpra nginx buffer.")

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

(defun xpra--cd-to-dir ()
  (let ((dir (locate-user-emacs-file "xpra")))
    (make-directory dir t)
    (set-file-modes dir #o700)
    (setq default-directory dir)))

(defun xpra--nginx-start ()
  (interactive)
  (with-current-buffer (get-buffer-create xpra-nginx-buffer-name)
    (while-let ((proc (get-buffer-process (current-buffer))))
      (kill-process proc)
      (while (accept-process-output proc))
      (sit-for 0.2)
      (delete-process proc))
    (comint-mode)
    (erase-buffer)
    (insert "xpra nginx server logs:\n")
    ;; nginx must be in the xpra dir so that it can open the sockets.
    (xpra--cd-to-dir)
    (let ((keyname "key.pem")
	  (certname "cert.pem"))
      ;; These names are hardcoded in the nginx configuration.
      (if (or xpra-ssl-key xpra-ssl-cert)
	  (progn
	    (make-symbolic-link xpra-ssl-key keyname t)
	    (make-symbolic-link xpra-ssl-cert certname t))
	(unless (and (file-exists-p keyname) (file-exists-p certname))
	  (message "Generating self-signed certs.")
	  (shell-command
	   (concat
	    "openssl req -x509 -newkey rsa:4096 -keyout " keyname " -out " certname " -sha256 -days 3650 -nodes -subj /C=US/CN=" fqdn))))
      (cl-assert (file-exists-p keyname))
      (cl-assert (file-exists-p certname)))
    (make-symbolic-link "/home/sbaugh/src/xpra-html5/html5" "html" t)
    (make-symbolic-link "/home/sbaugh/src/xpra.el/nginx.conf" "nginx.conf" t)
    (make-process
     :name "xpra-nginx"
     :buffer (current-buffer)
     :command
     `(,xpra-nginx-exe
       "-e" "/dev/stderr"
       "-p" "."
       "-c" "nginx.conf")
     :connection-type 'pipe
     :noquery t)))

(defun xpra-start (&optional interactive)
  (interactive "p")
  (with-current-buffer (get-buffer-create (format xpra-buffer-name "new"))
    (while-let ((proc (get-buffer-process (current-buffer))))
      (delete-process proc))
    (comint-mode)
    (erase-buffer)
    (insert "xpra server logs:\n")
    (xpra--cd-to-dir)
    (let* ((fqdn (string-trim (shell-command-to-string "hostname --fqdn")))
	   (sockname (format "emacs-x%s" (xpra--make-password)))
	   (url (format "https://%s:10443/%s" fqdn sockname)))
      (let ((process-environment
	     (append '("XPRA_EXPORT_MENU_DATA=false"
		       ;; Suppress the `server-create-dumb-terminal-frame' (buggy) behavior.
		       "TERM=notdumb")
		     process-environment)))
	(make-process
	 :name "xpra"
	 :buffer (current-buffer)
	 :command
	 `(,xpra-exe
	   "start"
	   ,@xpra-additional-args
	   "--daemon=no"
	   ,(format "--bind=%s" (expand-file-name sockname))
	   ,(format "--server-idle-timeout=%s" xpra-idle-timeout)
	   "--exit-with-children" "--terminate-children=yes"
	   "--start-child=emacsclient --frame-parameters='((fullscreen . fullboth))' --create-frame"
	   "--html=/home/sbaugh/src/xpra-html5/html5")
	 :connection-type 'pipe
	 :noquery t))
      (when interactive
	;; TODO we should print this message *after* receiving the frame connection...
	(message "Frame on %s" url)
	(kill-new url))
      url)))

(provide 'xpra)
;;; xpra.el ends here
