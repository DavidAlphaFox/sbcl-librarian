(require "asdf")

;; Loading swank on Windows throws a deprecation warning which crashes
;; compilation, so we ignore it.
#+win32
(setq uiop:*compile-file-failure-behaviour* :warn)

(when (uiop:getenv "CI")
  (push :github-ci *features*))

(asdf:load-system :sbcl-librarian)
(handler-bind ((deprecation-condition #'continue))
  (asdf:load-system :swank))

(defpackage #:sbcl-librarian/lib
  (:use #:cl #:sbcl-librarian)
  (:shadowing-import-from #:sbcl-librarian
			  #:warning #:error #:assert))

(in-package #:sbcl-librarian/lib)

(define-aggregate-library sbcl-librarian (:function-linkage "LIBSBCL_LIBRARIAN_API")
  diagnostics
  environment
  errors
  handles
  loader)

;;; BEGIN HACKS

;; Turn off SIGFPE handling by masking all floating point modes,
;; becuase libyaml signals SIGFPE... The core saves the state of the
;; modes so it remains off on startup.
(sb-int::set-floating-point-modes :traps '())

;;; We want the "ordinary" Ctrl+C behavior on Windows, i.e. whatever the
;;; application depending on libsbcl_librarian.dll happens to choose.
#+win32
(progn
  (sb-ext:unlock-package :sb-win32)
  (setf (symbol-function 'sb-win32::initialize-console-control-handler) (constantly nil)))

;;; END HACKS

;;; hacks to the dynamic library search path on macOS -- the goal here
;;; is to ensure we look in the conda lib dir
(defun write-python-header (library stream &optional (omit-init-call nil) (library-path nil))
  (let ((name (sbcl-librarian::library-c-name library)))
    (format stream "#~%")
    (format stream "# THIS FILE IS AUTOGENERATED~%")
    (format stream "#~%")
    (format stream "# isort: skip_file~%")
    (format stream "# mypy: ignore-errors~%")
    (format stream "# ruff: noqa~%~%")
    (format stream "import os~%")
    (format stream "import platform~%")
    (format stream "import signal~%")
    (format stream "from ctypes import *~%")
    (format stream "from ctypes.util import find_library~%")
    (format stream "from pathlib import Path~%~%")
    (format stream "import sbcl_librarian.wrapper~%")
    (format stream "from sbcl_librarian.errors import lisp_err_t~%~%")

    (format stream "def find_~a():~%" name)
    (format stream "    if platform.system() == 'Windows' or platform.system() == 'Linux':~%")
    (format stream "        return find_library('~a')~%" name)
    (format stream "    elif platform.system() == 'Darwin':~%")
    (format stream "        # cf. https://github.com/ContinuumIO/anaconda-issues/issues/1716~%")
    (format stream "        fallback_path = os.environ.get('DYLD_FALLBACK_LIBRARY_PATH', '')~%")
    (format stream "        conda_path = os.environ.get('CONDA_PREFIX')~%")
    (format stream "        try:~%")
    (format stream "            os.environ['DYLD_FALLBACK_LIBRARY_PATH'] = (conda_path+'/lib:'+fallback_path) if conda_path else fallback_path~%")
    (format stream "            return find_library('~a')~%" name)
    (format stream "        finally:~%")
    (format stream "            os.environ['DYLD_FALLBACK_LIBRARY_PATH'] = fallback_path~%")
    (format stream "    else:~%")
    (format stream "        raise Exception(f'Unexpected platform {platform.system()}')~%~%")

    (format stream "try:~%")
    ;; If we're in the GitHub CI workflow for Windows, hardcode the
    ;; path to sbcl_librarian.dll.
    #+(and win32 github-ci)
    (format stream "    libpath = Path(os.path.join(os.environ['CONDA_PREFIX'], 'bin', 'sbcl_librarian.dll')).resolve()~%")
    #-(and win32 github-ci)
    (format stream "    libpath = Path(find_~a()).resolve()~%" name)
    (format stream "except Exception as e:~%")
    (format stream "    raise Exception('Unable to locate ~a') from e~%~%" name)

    (format stream "_int_handler = signal.getsignal(signal.SIGINT)~%")
    (format stream "_term_handler = signal.getsignal(signal.SIGTERM)~%")
    (format stream "if platform.system() != \"Windows\":
    _chld_handler = signal.getsignal(signal.SIGCHLD)~%")
    (format stream "~a_dll = CDLL(str(libpath), mode=RTLD_GLOBAL)~%~%" name)
    (format stream "if platform.system() != \"Windows\":
    signal.signal(signal.SIGCHLD, _chld_handler)~%~%")
    (format stream "signal.signal(signal.SIGTERM, _term_handler)~%~%")
    (format stream "signal.signal(signal.SIGINT, _int_handler)~%~%")))

;; When this core file is reopened it will try to initialize all of
;; the alien callable symbols defined by the SBCL-LIBRARIAN aggregate
;; library. These symbols are exported by sbcl_librarian.dll.
;;
;; Problem: FIND-DYNAMIC-FOREIGN-SYMBOL-ADDRESS only searches for the
;; provided symbol in 1) the module containing the runtime, in this
;; case libsbcl.dll and 2) any DLL in the SB-SYS:*SHARED-OBJECTS*
;; list.
;;
;; Solution: call LOAD-SHARED-OBJECT on sbcl_librarian.dll the first
;; time we try to find one of its symbols, ensuring that it gets added
;; to *SHARED-OBJECTS*. Note that FASL libraries do the same thing by
;; calling the load_shared_object function exported by
;; sbcl_librarian.dll on themselves at library load time.
#+win32
(sb-int:encapsulate
 'sb-alien::find-dynamic-foreign-symbol-address
 'load-sbcl-librarian-dll
 (lambda (orig-find symbol)
   (sb-alien:load-shared-object "sbcl_librarian.dll")
   (unwind-protect
        (funcall orig-find symbol)
     (sb-int:unencapsulate
      'sb-alien::find-dynamic-foreign-symbol-address
      'load-sbcl-librarian-dll))))

(build-bindings sbcl-librarian "." :omit-init-function t)
(build-python-bindings sbcl-librarian "." :omit-init-call t :write-python-header-fn #'write-python-header)
(build-core-and-die sbcl-librarian ".")