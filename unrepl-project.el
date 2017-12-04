;;; unrepl-project.el --- Abstraction over multiple socket connections -*- lexical-binding: t; -*-
;;
;; Filename: unrepl-project.el
;; Author: Daniel Barreto <daniel@barreto.tech>
;; Maintainer: Daniel Barreto <daniel@barreto.tech>
;; Copyright (C) 2017 Daniel Barreto
;; Created: Sat Nov 11 01:55:58 2017 (+0100)
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Commentary:
;;
;; Abstraction over multiple socket connections
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or (at
;; your option) any later version.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Code:

(require 'clojure-mode)
(require 'dash)
(require 'map)
(require 'subr-x)

(require 'unrepl-ast)
(require 'unrepl-util)


(defcustom unrepl-classpath '()
  "Global classpath for UNREPL aux connections.
Ideal for REPL tooling."
  :type 'list
  :group 'unrepl)

(defvar unrepl-projects nil
  "AList containing all projects identified by a Connection ID \"host:port\".

Each element of this AList is also another AList containing a 'Connection
Pool', and optionally the `project-dir', `project-type', and `socket-repl'
process.")


(defvar-local unrepl-pending-evals nil
  "Queue of pending evaluations.
This variable is meant to be set on network buffers for `:client' and
`:aux' interactions with an UNREPL server.")


;; Pending Evaluations
;; -------------------------------------------------------------------
;; Projects store a queue of pending evaluations in each of their connection
;; process' buffers.  Each pending evaluation is an associative data structure
;; that contains the following:
;; - `:status': either `:sent', `:read', `:started-eval', `:eval', or
;;   `:exception'.
;; - `:group-id': An UNREPL group id.  Set after the pending evaluation gets
;;    `:read'.
;; - `actions': Evaluation actions as provided by the `started-eval' UNREPL.
;;    Set after the pending has `started-eval'.
;; - `:repl-history-idx': (optional) only if the input was sent from the REPL,
;;    this would be the index in REPL history.
;; - `:prompt-marker': (optional) a REPL buffer position to which print either
;;    evaluation outputs or `:out' strings.
;;
;; Pending evaluations' life cycle start when an input string is sent to the
;; UNREPL server (either by using the human REPL interface, or by evaluating
;; clojure buffer code).  At this very moment, a pending evaluation is created
;; with only a status `:sent', and it will be put in the pending evaluations
;; queue.  Any other input sent while processing this pending evaluation, will
;; generate new pending evaluation entries that will be added to the queue and
;; processed in order.
;; An input string sent to the UNREPL server will generate ideally 1 `:read'
;; message back from the server, but in general, it can generate 0 or more of
;; them.
;;
;; The first `:read' message received after sending input stream will be used to
;; update the pending evaluation status, add a group id, and, if the input came
;; from the REPL, update its prompt marker.
;; `:started-eval' messages will be used to add a set of actions to the pending
;; evaluation structure.
;; When `:eval' messages are received (or `:exception's), we will display them
;; according to how the input was generated in the first place (REPL or buffer
;; eval)
;; Subsequent `:read' messages received for the same input (or put in a
;; different way, not interrupted by another `:prompt' message) will modify the
;; same pending evaluation as their predecessors, making sure to delete from it
;; the actions and group-id information.
;;
;; When a `:prompt' is received again, the top of the queue (`:eval'ed pending
;; evaluation) will be taken out, and the process start again.

(defmacro with-process-buffer (conn-id type &rest body)
  "Execute BODY in the buffer for the TYPE connection of CONN-ID."
  (declare (indent 2))
  `(let* ((project (unrepl-projects-get ,conn-id))
          (proc (unrepl-project-conn-pool-get-process project ,type)))
     (with-current-buffer (process-buffer proc)
       ,@body)))


(defun unrepl-pending-eval (type conn-id)
  "Return the beginning of CONN-ID TYPE's pending-evals queue."
  (with-process-buffer conn-id type
    (car unrepl-pending-evals)))


(defun unrepl-pending-eval-add (type conn-id &rest kwargs)
  "Add a pending evaluation to CONN-ID TYPE'S pending-evals queue.
KWARGS are key-values used to create the pending evaluation entry."
  (with-process-buffer conn-id type
    (let* ((entry (mapcar (lambda (pair)
                            (cons (car pair) (cadr pair)))
                          (-partition 2 kwargs))))
      (setq unrepl-pending-evals
            (nconc unrepl-pending-evals `(,entry))))))


(defun unrepl-pending-eval-update (type conn-id &rest kwargs)
  "Update the first entry at CONN-ID TYPE's pending-evals queue.
KWARGS are the key-values to update the pending evaluation entry."
  (with-process-buffer conn-id type
    (let* ((entry (car unrepl-pending-evals)))
      (mapc (lambda (kv) (map-put entry (car kv) (cadr kv)))
            (-partition 2 kwargs))
      (setq unrepl-pending-evals
            (cons entry (cdr unrepl-pending-evals))))))


(defun unrepl-pending-eval-history-idx (type conn-id)
  "Return the `:repl-history-idx' from the top of the CONN-ID TYPE's queue."
  (with-process-buffer conn-id type
    (-> unrepl-pending-evals
        (car)
        (map-elt :repl-history-idx))))


(defun unrepl-pending-eval-callback (type conn-id)
  "Return the `:eval-callback' from the top of the CONN-ID TYPE's pending-evals queue."
  (with-process-buffer conn-id type
    (-> unrepl-pending-evals
        (car)
        (map-elt :eval-callback))))


(defun unrepl-pending-eval-stdout-callback (type conn-id)
  "Return the `:stdout-callback' from the top of the CONN-ID TYPE's pending-evals queue."
  (with-process-buffer conn-id type
    (-> unrepl-pending-evals
        (car)
        (map-elt :stdout-callback))))


(defun unrepl-pending-eval-actions (type conn-id)
  "Return `:actions' from the top of the CONN-ID TYPE's pending-evals queue."
  (with-process-buffer conn-id type
    (-> unrepl-pending-evals
        (car)
        (map-elt :actions))))


(defun unrepl-pending-eval-group-id (type conn-id)
  "Return `:group-id' from the top of the CONN-ID TYPE's pending-evals queue."
  (with-process-buffer conn-id type
    (-> unrepl-pending-evals
        (car)
        (map-elt :group-id))))


(defun unrepl-pending-evals-shift (type conn-id)
  "Shift the CONN-ID TYPE's `:pending-evals' queue and return the shifted entry."
  (with-process-buffer conn-id type
    (let* ((entry (car unrepl-pending-evals)))
      (setq unrepl-pending-evals (cdr unrepl-pending-evals))
      entry)))


(defun unrepl-pending-eval-entry-status (entry)
  "Return the `:status' from a pending eval ENTRY."
  (map-elt entry :status))


(defun unrepl-pending-eval-entry-history-idx (entry)
  "Return the `:repl-history-idx' from a pending eval ENTRY."
  (map-elt entry :repl-history-idx))


(defun unrepl-pending-eval-entry-buffer (entry)
  "Return the `:buffer' from a pending eval ENTRY."
  (map-elt entry :buffer))


(defun unrepl-pending-eval-entry-group-id (entry)
  "Return the `:group-id' from a pending eval ENTRY."
  (map-elt entry :group-id))


(defun unrepl-pending-eval-entry-input (entry)
  "Return the `:input' from a pending eval ENTRY."
  (map-elt entry :input))


(defun unrepl-pending-eval-entry-payload (entry)
  "Return the `:payload' from a pending eval ENTRY."
  (map-elt entry :payload))


(defun unrepl-pending-eval-entry-actions (entry)
  "Return the `:actions' from a pending eval ENTRY."
  (map-elt entry :actions))


;; UNREPL Projects
;; -------------------------------------------------------------------
;; `unrepl-projects' is an associative data structure where keys are Connection
;; IDs and values are Project data structures.
;; A Project is an associative data structure that holds:
;; - `:id': A Connection ID.
;; - `:conn-pool': An AList with the 3 UNREPL connections for this project.
;; - `:pending-evals': A Pending Evals data structure.
;; - `:repl-buffer': A buffer that holds human-focused REPL interaction.
;; - `:project-dir': An optional stringn pointing to the project's dir.
;; - `:project-type': An optional string referring to the type of project.
;; - `:socket-repl': An optional process referring to the Socket REPL server.

(declare-function unrepl-repl-create-buffer "unrepl-repl")
(defun unrepl-create-project (conn-id project-dir conn-pool server-proc)
  "Create a new project structure with id CONN-ID.
PROJECT-DIR is the Clojure project's directory, it can be nil.
CONN-POOL is the connection pool, as described in the documentation.
SERVER-PROC is an optional process representing the Clojure Socket REPL.

The returned data structure is meant to be placed in `unrepl-projects'."
  `((:id . ,conn-id)
    (:created . ,(current-time))
    (:namespace . nil)
    (:project-dir . ,project-dir)
    (:socket-repl . ,server-proc)
    (:repl-buffer . ,(unrepl-repl-create-buffer conn-id))
    (:conn-pool . ,conn-pool)))


(declare-function unrepl--conn-pool-procs "unrepl")
(declare-function unrepl-repl-disconnect "unrepl-repl")
(defun unrepl-project-quit (conn-id &optional message)
  "Kill and remove project with CONN-ID.
If MESSAGE is non-nil, it will be displayed at the end of the REPL
buffer, which won't be automatically killed."
  (interactive)
  (let* ((proj (unrepl-projects-get conn-id))
         (repl-buf (unrepl-project-repl-buffer proj))
         (server-proc (unrepl-project-socket-repl proj))
         (server-buf (when server-proc (process-buffer server-proc)))
         (pool (unrepl-project-conn-pool proj)))
    ;; Kill the main Socket REPL, if any.
    (when server-proc
      (delete-process server-proc))
    (when server-buf
      (kill-buffer server-buf))
    ;; Kill the pool connection processes.
    (mapc (lambda (p-conn)
            (let* ((p-conn-proc (cdr p-conn))
                   (p-conn-buf (process-buffer p-conn-proc)))
              (when p-conn-proc
                (delete-process p-conn-proc))
              (when p-conn-buf
                (kill-buffer p-conn-buf))))
          pool)
    ;; Handle REPL buffer, if there's a message display it, if not, kill it
    (if message
        (unrepl-repl-disconnect conn-id message)
      (when repl-buf
        (kill-buffer repl-buf)))
    ;; Search for all buffers connected to this project and unbind their connection.
    (mapc (lambda (unrepl-buf)
            (with-current-buffer unrepl-buf
              (kill-local-variable 'unrepl-conn-id)))
          (unrepl-project-buffers proj))
    ;; Remove the entry from `unrepl-projects'
    (setq unrepl-projects (map-delete unrepl-projects conn-id))))


(defun unrepl-project-id (proj)
  "Return the ID of the given PROJ."
  (map-elt proj :id))


(defun unrepl-project-repr (proj)
  "Return a human focused string representation of PROJ."
  (let* ((dir (unrepl-project-dir proj)))
    (if-let (name (when dir
                    (file-name-nondirectory (substring dir 0 -1))))
        (format "%s [%s]" name (unrepl-project-id proj))
      (format "%s" (unrepl-project-id proj)))))

(defun unrepl-project-created (proj)
  "Return the created time for PROJ."
  (map-elt proj :created))


(defun unrepl-project-port (proj)
  "Return the Socket REPL port for the given PROJ."
  (cdr (unrepl-conn-host-port (unrepl-project-id proj))))


(defun unrepl-project-repl-buffer (proj)
  "Return the REPL buffer for the given PROJ."
  (map-elt proj :repl-buffer))


(defun unrepl-project-host (proj)
  "Return the Socket REPL host for the given PROJ."
  (car (unrepl-conn-host-port (unrepl-project-id proj))))


(defun unrepl-project-namespace (proj)
  "Return the current namespace used in PROJ."
  (map-elt proj :namespace))


(defun unrepl-project-dir (proj)
  "Return the directory of the given PROJ."
  (map-elt proj :project-dir))


(defun unrepl-project-socket-repl (proj)
  "Return a plist with the `:host' `:port' kv pairs for the PROJ's Socket REPL."
  (map-elt proj :socket-repl))


(defun unrepl-project-classpath (proj)
  "Return the global `unrepl-classpath' list appended to PROJ's classpath.
This function ensures that every path/file in the returned classpath exists
and its expanded."
  (mapcar
   #'file-truename
   (seq-filter
    (lambda (path) (when path (file-exists-p path)))
    (append (list (unrepl-project-dir proj))
            (map-elt proj :classpath)
            unrepl-classpath))))


(defun unrepl-project-conn-pool (proj)
  "Return the PROJ's 'Connection Pool'."
  (map-elt proj :conn-pool))


(defun unrepl-project-conn-pool-get-process (proj type)
  "Return the TYPE network process for the given PROJ."
  (map-elt (unrepl-project-conn-pool proj) type))


(defun unrepl-project-conn-pool-set-in (conn-id &rest kwargs)
  "Set new key-vals in CONN-ID's `:conn-pool', provided by KWARGS.
KWARGS is expected to be pairs of keywords and processes."
  (let* ((proj (unrepl-projects-get conn-id))
         (conn-pool (unrepl-project-conn-pool proj)))
    (mapc (lambda (pair)
            (map-put conn-pool (car pair) (cadr pair)))
          (-partition 2 kwargs))
    (unrepl-project-set-in conn-id :conn-pool conn-pool)))


(defun unrepl-project-actions (project)
  "Return all `:actions' in PROJECT."
  (map-elt project :actions))


(defun unrepl-project-actions-get (project action)
  "Return ACTION in PROJECT's `:actions'.
ACTION should be a key in the UNREPL session-actions map."
  (unrepl-ast-map-elt (unrepl-project-actions project) action))


(defun unrepl-project-buffers (project &optional require-connected)
  "Return a list of buffers that belong to this PROJECT's directory.
REQUIRE-CONNECTED is an optional conn-id to filter only those buffers that
are already connected to it."
  (when-let ((dir (unrepl-project-dir project)))
    (-filter (lambda (b)
               (with-current-buffer b
                 (and (string-prefix-p dir buffer-file-name)
                      (derived-mode-p 'clojure-mode)
                      (or (not require-connected)
                          (and (bound-and-true-p unrepl-conn-id)
                               (eql unrepl-conn-id require-connected))))))
             (buffer-list))))


(defun unrepl-projects-as-list ()
  "Return all available projects as a list, sorted by creation date."
  (-sort (lambda (p1 p2)
           (time-less-p (unrepl-project-created p2)
                        (unrepl-project-created p1)))
         (map-values unrepl-projects)))


(defun unrepl-projects-add (proj)
  "Add PROJ to `unrepl-projects'."
  (map-put unrepl-projects (unrepl-project-id proj) proj))


(defun unrepl-projects-get (conn-id &optional raise-not-found)
  "Return the project with CONN-ID, or nil.
When RAISE-NOT-FOUND is nil, raises an `error' if CONN-ID is not found in
`unrepl-projects'."
  (let ((proj (map-elt unrepl-projects conn-id)))
    (when (and raise-not-found
               (not proj))
      (error "No project connected to %s can be found" conn-id))
    proj))


(defun unrepl-projects-get-by-dir (project-dir)
  "Find a project in `unrepl-projects' for PROJECT-DIR.
If more than one project matches with PROJECT-DIR, return the most recently
created.
Return matching project or nil"
  (-find (lambda (p) (string= (unrepl-project-dir p) project-dir))
         (unrepl-projects-as-list)))


(defun unrepl-project-set-in (conn-id key val)
  "Set an attribute in the `unrepl-projects' project with key CONN-ID.
KEY is expected to be a keyword, VAL is its corresponding value."
  (let ((proj (unrepl-projects-get conn-id t)))
    (map-put proj key val)
    (map-put unrepl-projects conn-id proj)
    unrepl-projects))


(provide 'unrepl-project)

;;; unrepl-project.el ends here
