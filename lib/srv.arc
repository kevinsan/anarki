; HTTP Server.

; To improve performance with static files, set static-max-age*.

(= arcdir* "arc/" logdir* "arc/logs/" staticdir* "static/")

(= quitsrv* nil breaksrv* nil)

(def serve ((o port 8080))
  (wipe quitsrv*)
  (ensure-srvdirs)
  (map [apply new-bgthread _] pending-bgthreads*)
  (w/socket s port
    (setuid 2) ; XXX switch from root to pg
    (prn "ready to serve port " port)
    (flushout)
    (= currsock* s)
    (until quitsrv*
      (handle-request s breaksrv*)))
  (prn "quit server"))

(def serve1 ((o port 8080))
  (w/socket s port (handle-request s t)))

(def ensure-srvdirs ()
  (map ensure-dir (list arcdir* logdir* staticdir*)))

(= srv-noisy* nil)

; http requests currently capped to upload-limit* bytes
; see socket-accept

; should threads process requests one at a time? no, then
; a browser that's slow consuming the data could hang the
; whole server.

; wait for a connection from a browser and start a thread
; to handle it. also arrange to kill that thread if it
; has not completed in threadlife* seconds.

(= threadlife* 30  requests* 0  requests/ip* (table)
   throttle-ips* (table)  ignore-ips* (table)  spurned* (table))

(def handle-request (s breaksrv)
  (if breaksrv
    (handle-request-1 s)
    (errsafe (handle-request-1 s))))

(def handle-request-1 (s)
  (with ((in out ip) (socket-accept s)
         th1 nil th2 nil)
    (++ requests*)
    (let ip-wrapper (fn args
                      (if args
                        (= ip car.args)
                        ip))
      (= th1 (thread
               (after (handle-request-thread in out ip-wrapper)
                      (close in out)
                      (kill-thread th2))))
      (= th2 (thread
               (sleep threadlife*)
               (unless (dead th1)
                 (prn "srv thread took too long for " ip))
               (kill-thread th1)
               (force-close in out))))))

; Returns true if ip has made req-limit* requests in less than
; req-window* seconds.  If an ip is throttled, only 1 request is
; allowed per req-window* seconds.  If an ip makes req-limit*
; requests in less than dos-window* seconds, it is a treated as a DoS
; attack and put in ignore-ips* (for this server invocation).

; To adjust this while running, adjust the req-window* time, not
; req-limit*, because algorithm doesn't enforce decreases in the latter.

(= req-times* (table) req-limit* 30 req-window* 10 dos-window* 2)

(def abusive-ip (ip)
  (++ (requests/ip* ip 0))
  (when (or (ignore-ips* ip) (abusive-ip-core ip))
    (when (~spurned* ip)
      (prn "throttling abusive ip " ip))
    (++ (spurned* ip 0))))

(def abusive-ip-core (ip)
  (and (only.> (requests/ip* ip) 250)
       (let now (seconds)
         (do1 (if (req-times* ip)
                (and (>= (qlen (req-times* ip))
                         (if (throttle-ips* ip) 1 req-limit*))
                     (let dt (- now (deq (req-times* ip)))
                       (if (< dt dos-window*) (set (ignore-ips* ip)))
                       (< dt req-window*)))
                (do (= (req-times* ip) (queue))
                    nil))
              (enq now (req-times* ip))))))

(let proxy-header "X-Forwarded-For: "
  (def strip-header(s)
    (subst "" proxy-header s))
  (def proxy-ip(ip-wrapper lines)
    (aif (only.strip-header (car:keep [headmatch proxy-header _] lines))
      (ip-wrapper it)
      (ip-wrapper))))

(wipe show-requests*)
(def handle-request-thread (in out ip-wrapper)
  (with (nls 0 lines nil line nil responded nil t0 (msec))
    (after
      (whilet c (unless responded (readc in))
        (if srv-noisy* (pr c))
        (if (is c #\newline)
          (if (is (++ nls) 2)
            (let (type op args clen cooks ctype) (parseheader (rev lines))
              (if show-requests* (prn lines))
              (unless (abusive-ip (proxy-ip ip-wrapper lines))
                (let t1 (msec)
                  (case type
                    get  (respond out op args cooks 0 in "" (ip-wrapper))
                    post (handle-post in out op args clen cooks ctype (ip-wrapper))
                         (respond-err out "Unknown request: " (car lines)))
                  (log-request type op args cooks (ip-wrapper) t0 t1)))
              (set responded))
            (do (push (string (rev line)) lines)
                (wipe line)))
          (unless (is c #\return)
            (push c line)
            (= nls 0))))
      (close in out)))
  (harvest-fnids))

(def log-request (type op args cooks ip t0 t1)
  (with (parsetime (- t1 t0) respondtime (- (msec) t1))
    (srvlog 'srv ip
                 parsetime
                 respondtime
                 (if (> (+ parsetime respondtime) 1000) "***" "")
                 type
                 op
                 (let arg1 (car args)
                   (if (caris arg1 "fnid") "" arg1))
                 cooks)))

(= header* "HTTP/1.1 200 OK\r
Content-Type: text/html; charset=utf-8\r
Connection: close")

(= err-header* "HTTP/1.1 404 Not Found\r
Content-Type: text/html; charset=utf-8\r
Connection: close")

(def static-filetype (sym)
  (let fname (coerce sym 'string)
    (and (~findsubseq ".." fname) ; for security
         (case (downcase (last (check (tokens fname #\.) ~single)))
           "gif"  'image/gif
           "jpg"  'image/jpg
           "jpeg" 'image/jpg
           "png"  'image/png
           "css"  'text/plain
           "js"   'text/javascript
           "txt"  'text/plain
           "htm"  'text/html
           "html" 'text/html
           "arc"  'text/plain
           ))))

(= rdheader* "HTTP/1.0 302 Moved")

(= srvops* (table) redirector* (table) optimes* (table) opcounts* (table))

(def save-optime (name elapsed)
  ; this is the place to put a/b testing
  ; toggle a flag and push elapsed into one of two lists
  (++ (opcounts* name 0))
  (unless (optimes* name) (= (optimes* name) (queue)))
  (enq-limit elapsed (optimes* name) 1000))

; For ops that want to add their own headers.  They must thus remember
; to prrn a blank line before anything meant to be part of the page.

(mac defop-raw (name parms . body)
  (w/uniq t1
    `(= (srvops* ',name)
        (fn ,parms
          (let ,t1 (msec)
            (do1 (do ,@body)
                 (save-optime ',name (- (msec) ,t1))))))))

(mac defopr-raw (name parms . body)
  `(= (redirector* ',name) t
      (srvops* ',name)     (fn ,parms ,@body)))

(mac defop (name parm . body)
  (w/uniq gs
    `(do (wipe (redirector* ',name))
         (defop-raw ,name (,gs ,parm)
           (w/stdout ,gs (prrn) ,@body)))))

; Defines op as a redirector.  Its retval is new location.

(mac defopr (name parm . body)
  (w/uniq gs
    `(do (set (redirector* ',name))
         (defop-raw ,name (,gs ,parm)
           ,@body))))

;(mac testop (name . args) `((srvops* ',name) ,@args))

(deftem request
  args  nil
  cooks nil
  ctype nil
  clen  0
  in    nil
  ip    nil)

(= unknown-msg* "Unknown." max-age* (table) static-max-age* nil)

(def respond (str op args cooks clen ctype in ip)
  (w/stdout str
    (iflet f (srvops* op)
      (let req (inst 'request 'args args 'cooks cooks 'ctype ctype 'clen clen 'in in 'ip ip)
        (if (redirector* op)
          (do (prrn rdheader*)
              (prrn "Location: " (f str req))
              (prrn))
          (do (prrn header*)
              (awhen (max-age* op)
                (prrn "Cache-Control: max-age=" it))
              (f str req))))
      (let filetype (static-filetype op)
        (aif (and filetype (file-exists (string staticdir* op)))
          (do (prrn "HTTP/1.0 200 OK")
              (prrn "Content-Type: " filetype
                   (if (litmatch "text" filetype)
                     "; charset=utf-8"
                     ""))
              (prrn "Connection: close")
              (awhen static-max-age*
                (prrn "Cache-Control: max-age=" it))
              (prrn)
              (w/infile i it
                (whilet b (readb i)
                  (writeb b str))))
          (respond-err str unknown-msg*))))))

(def handle-post (in out op args clen cooks ctype ip)
  (if (no clen)
    (respond-err out "Post request without Content-Length.")
    (respond out op (+ args
                       (if (~begins downcase.ctype "multipart/form-data")
                         (parseargs:string:readchars clen in) ; ascii
                         (parse-multipart-args multipart-boundary.ctype in))) ; maybe non-ascii
             cooks clen ctype in ip)))

(def multipart-boundary(s)
  (let delim "boundary="
    (+ "--" (cut s (+ (findsubseq delim s)
                      len.delim)))))

(def parse-multipart-args(boundary in)
  (scan-past boundary in) ; skip prelude
  (accum yield
    (until (multipart-end boundary in)
      (withs (headers   scan-headers.in
              body  (scan-body boundary in)) ; only part that may contain non-ascii
        (when headers
          (yield:parse-multipart-part headers body))))))

; "The final boundary is followed by two more hyphens to indicate that no
; further parts follow."
;   -- http://www.w3.org/Protocols/rfc1341/7_2_Multipart.html
; We've already read the boundary itself.
(def multipart-end(boundary in)
  (aif peekc.in
    (and (is #\- it) readc.in
         (or (is #\- peekc.in)
             ; "one #\- shalt thou not count,
             ; excepting that thou then proceed to two"
             (ero "malformed multipart input; boundary followed by just one '-'. Is it the final part or isn't it?")))
    (ero "malformed multipart input; request didn't have a final boundary")))

(def scan-headers(in)
  ; "The boundary must be followed immediately either by another CRLF and the
  ; header fields for the next part, or by two CRLFs, in which case there are no
  ; header fields for the next part.."
  ;   -- http://www.w3.org/Protocols/rfc1341/7_2_Multipart.html
  (parse-mime-header:bytes-string:scan-past "\r\n\r\n" in))

(def scan-body(boundary in)
  ; "The CRLF preceding the encapsulation line is considered part of the
  ; boundary.."
  ;   -- http://www.w3.org/Protocols/rfc1341/7_2_Multipart.html
  (scan-past (+ "\r\n" boundary) in))

(def parse-multipart-part(headers body)
  (awhen (and headers (alref headers "name"))
    (list unstring.it
          (w/table multipart-arg
            (= (multipart-arg "contents")
               (if (all-ascii? body)
                 bytes-string.body
                 body))
            (each (property val) headers
              (unless (iso "name" property)
                (= multipart-arg.property val)))))))

; parse lines of the form a=b; c=d; e=f; ..
; segments without '=' are passed through as single-elem lists
(def parse-mime-header(line)
  (map [tokens _ #\=]
       (tokens downcase.line (orf whitec (testify #\;)))))

; return list of bytes until pat is encountered
; pat is read from input but dropped from result
; all chars in pat must be 1-byte
(def scan-past(pat in)
  (= pat (map int (coerce pat 'cons)))
  (let buffer (spliceable-list len.pat)
    (until (iso pat suffix.buffer)
      (append buffer (list readb.in)))
    splice.buffer))

; convert list of bytes to string
(def bytes-string(l)
  (coerce (map [coerce _ 'char]
               l)
          'string))

(def all-ascii?(l)
  (errsafe:all [<= 0 _ 127] l))

; "\"abc\"" => "abc"
(def unstring(s)
  (if (iso #\" s.0)
    (cut s 1 -1)
    s))

(def respond-err (str msg . args)
  (w/stdout str
    (prrn err-header*)
    (prrn)
    (apply pr msg args)))

(def parseheader (lines)
  (let (type op args) (parseurl (car lines))
    (list type
          op
          args
          (and (is type 'post)
               (some (fn (s)
                       (and (begins downcase.s "content-length:")
                            (errsafe:coerce (cadr (tokens s)) 'int)))
                     (cdr lines)))
          (some (fn (s)
                  (and (begins downcase.s "cookie:")
                       (parsecookies s)))
                (cdr lines))
          (and (is type 'post)
               (some (fn (s)
                       (and (begins downcase.s "content-type: ")
                            (cut s (len "content-type: "))))
                     (cdr lines))))))

; (parseurl "GET /p1?foo=bar&ug etc") -> (get p1 (("foo" "bar") ("ug")))

(def parseurl (s)
  (let (type url) (tokens s)
    (let (base args) (tokens url #\?)
      (list (sym (downcase type))
            (sym (cut base 1))
            (if args
              (parseargs args))))))

; I don't urldecode field names or anything in cookies; correct?

(def parseargs (s)
  (map (fn ((k v)) (list k urldecode.v))
       (map [tokens _ #\=] (tokens s #\&))))

(def parsecookies (s)
  (map [tokens _ #\=]
       (cdr (tokens s [or whitec._ (is _ #\;)]))))

(def arg (req key)
  (acheck (alref req!args key) [~isa _ 'table]
    ; deref multipart params by default
    (it "contents")))

(def multipart-metadata(req arg key)
  (let val (alref req!args arg)
    (if (isa val 'table)
      val.key)))

; *** Warning: does not currently urlencode args, so if need to do
; that replace v with (urlencode v).

(def reassemble-args (req)
  (aif req!args
    (apply string "?" (intersperse '&
                                   (map (fn ((k v))
                                          (string k '= v))
                                        it)))
    ""))

(= fns* (table) fnids* nil timed-fnids* nil)

; count on huge (expt 64 10) size of fnid space to avoid clashes

(def new-fnid ()
  (check (sym (rand-string 10)) ~fns* (new-fnid)))

(def fnid (f)
  (atlet key (new-fnid)
    (= (fns* key) f)
    (push key fnids*)
    key))

(def timed-fnid (lasts f)
  (atlet key (new-fnid)
    (= (fns* key) f)
    (push (list key (seconds) lasts) timed-fnids*)
    key))

; Within f, it will be bound to the fn's own fnid.  Remember that this is
; so low-level that need to generate the newline to separate from the headers
; within the body of f.

(mac afnid (f)
  `(atlet it (new-fnid)
     (= (fns* it) ,f)
     (push it fnids*)
     it))

;(defop test-afnid req
;  (tag (a href (url-for (afnid (fn (req) (prrn) (pr "my fnid is " it)))))
;    (pr "click here")))

; To be more sophisticated, instead of killing fnids, could first
; replace them with fns that tell the server it's harvesting too
; aggressively if they start to get called.  But the right thing to
; do is estimate what the max no of fnids can be and set the harvest
; limit there-- beyond that the only solution is to buy more memory.

(def harvest-fnids ((o n 50000))  ; was 20000
  (when (len> fns* n)
    (pull (fn ((id created lasts))
            (when (> (since created) lasts)
              (wipe (fns* id))
              t))
          timed-fnids*)
    (atlet nharvest (trunc (/ n 10))
      (let (kill keep) (split (rev fnids*) nharvest)
        (= fnids* (rev keep))
        (each id kill
          (wipe (fns* id)))))))

(= fnurl* "/x" rfnurl* "/r" rfnurl2* "/y" jfnurl* "/a")

(= dead-msg* "\nUnknown or expired link.")

(defop-raw x (str req)
  (w/stdout str
    (aif (arg req "fnid")
      (aif (fns* sym.it)
        (it req)
        (pr dead-msg*))
      (pr "\nno fnid"))))

(defopr-raw y (str req)
  (aif (fns* (sym (arg req "fnid")))
    (w/stdout str (it req))
    "deadlink"))

; For asynchronous calls; discards the page.  Would be better to tell
; the fn not to generate it.

(defop-raw a (str req)
  (aif (fns* (sym (arg req "fnid")))
    (tostring (it req))))

(defopr r req
  (aif (fns* (sym (arg req "fnid")))
    (it req)
    "deadlink"))

(defop deadlink req
  (pr dead-msg*))

(def url-for (fnid)
  (string fnurl* "?fnid=" fnid))

(def flink (f)
  (string fnurl* "?fnid=" (fnid (fn (req) (prrn) (f req)))))

(def rflink (f)
  (string rfnurl* "?fnid=" (fnid f)))

; Since it's just an expr, gensym a parm for (ignored) args.

(mac w/link (expr . body)
  `(tag (a href (flink (fn (,(uniq)) ,expr)))
     ,@body))

(mac w/rlink (expr . body)
  `(tag (a href (rflink (fn (,(uniq)) ,expr)))
     ,@body))

(mac onlink (text . body)
  `(w/link (do ,@body) (pr ,text)))

(mac onrlink (text . body)
  `(w/rlink (do ,@body) (pr ,text)))

; bad to have both flink and linkf; rename flink something like fnid-link

(mac linkf (text parms . body)
  `(tag (a href (flink (fn ,parms ,@body))) (pr ,text)))

(mac rlinkf (text parms . body)
  `(tag (a href (rflink (fn ,parms ,@body))) (pr ,text)))

;(defop top req (linkf 'whoami? (req) (pr "I am " (get-user req))))

;(defop testf req (w/link (pr "ha ha ha") (pr "laugh")))

(mac w/link-if (test expr . body)
  `(tag-if ,test (a href (flink (fn (,(uniq)) ,expr)))
     ,@body))

(def fnid-field (id)
  (gentag input type 'hidden name 'fnid value id))

; f should be a fn of one arg, which will be http request args.

(def fnform (f bodyfn (o redir))
  (tag (form method 'post action (if redir rfnurl2* fnurl*))
    (fnid-field (fnid f))
    (bodyfn)))

; Could also make a version that uses just an expr, and var capture.
; Is there a way to ensure user doesn't use "fnid" as a key?

(mac aform (f . body)
  (w/uniq ga
    `(tag (form method 'post action fnurl*)
       (fnid-field (fnid (fn (,ga)
                           (prrn)
                           (,f ,ga))))
       ,@body)))

(mac aform-multi (f . body)
  (w/uniq ga
    `(tag (form method 'post
                enctype "multipart/form-data"
                action (string fnurl* "?fnid="
                               (fnid (fn (,ga)
                                       (prrn)
                                       (,f ,ga)))))
       ,@body)))

(mac form-multi (action . body)
  (w/uniq ga
    `(tag (form method 'post
                enctype "multipart/form-data"
                action ,action)
       ,@body)))

;(defop test1 req
;  (fnform (fn (req) (prrn) (pr req))
;          (fn () (single-input "" 'foo 20 "submit"))))

;(defop test2 req
;  (aform (fn (req) (pr req))
;    (single-input "" 'foo 20 "submit")))

; Like aform except creates a fnid that will last for lasts seconds
; (unless the server is restarted).

(mac taform (lasts f . body)
  (w/uniq (gl gf gi ga)
    `(withs (,gl ,lasts
             ,gf (fn (,ga) (prrn) (,f ,ga)))
       (tag (form method 'post action fnurl*)
         (fnid-field (if ,gl (timed-fnid ,gl ,gf) (fnid ,gf)))
         ,@body))))

(mac arform (f . body)
  `(tag (form method 'post action rfnurl*)
     (fnid-field (fnid ,f))
     ,@body))

; overlong

(mac tarform (lasts f . body)
  (w/uniq (gl gf)
    `(withs (,gl ,lasts ,gf ,f)
       (tag (form method 'post action rfnurl*)
         (fnid-field (if ,gl (timed-fnid ,gl ,gf) (fnid ,gf)))
         ,@body))))

(mac aformh (f . body)
  `(tag (form method 'post action fnurl*)
     (fnid-field (fnid ,f))
     ,@body))

(mac arformh (f . body)
  `(tag (form method 'post action rfnurl2*)
     (fnid-field (fnid ,f))
     ,@body))

; only unique per server invocation

(= unique-ids* (table))

(def unique-id ((o len 8))
  (let id (sym (rand-string (max 5 len)))
    (if (unique-ids* id)
      (unique-id)
      (= (unique-ids* id) id))))

(def srvlog (type . args)
  (ontofile (logfile-name type)
            (atomic (apply prs (seconds) args) (prn))))

(def logfile-name (type)
  (string logdir* type "-" (memodate)))

(with (lastasked nil lastval nil)

(def memodate ()
  (let now (seconds)
    (if (or (no lastasked) (> (- now lastasked) 60))
      (= lastasked now lastval (datestring))
      lastval)))

)

(defop || req (pr "It's alive."))

(defop topips req
  (when (admin (get-user req))
    (whitepage
      (sptab
        (each ip (let leaders nil
                   (maptable (fn (ip n)
                               (when (> n 100)
                                 (insort (compare > requests/ip*)
                                         ip
                                         leaders)))
                             requests/ip*)
                   leaders)
          (let n (requests/ip* ip)
            (row ip n (pr (num (* 100 (/ n requests*)) 1)))))))))

(defop spurned req
  (when (admin (get-user req))
    (whitepage
      (sptab
        (map (fn ((ip n)) (row ip n))
             (sortable spurned*))))))

; eventually promote to general util

(def sortable (ht (o f >))
  (let res nil
    (maptable (fn kv
                (insort (compare f cadr) kv res))
              ht)
    res))


; Background Threads

(= bgthreads* (table) pending-bgthreads* nil)

(def new-bgthread (id f sec)
  (aif (bgthreads* id) (break-thread it))
  (= (bgthreads* id) (new-thread (fn ()
                                   (while t
                                     (sleep sec)
                                     (f))))))

; should be a macro for this?

(mac defbg (id sec . body)
  `(do (pull [caris _ ',id] pending-bgthreads*)
       (push (list ',id (fn () ,@body) ,sec)
             pending-bgthreads*)))



; Idea: make form fields that know their value type because of
; gensymed names, and so the receiving fn gets args that are not
; strings but parsed values.

