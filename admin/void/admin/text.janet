### void/admin/text — the back office's own words, in one table.
###
### Every string the admin puts on a page is a key here and nowhere
### else. `text/t` asks the bound catalog first, so an application that
### composes void/i18n translates the whole back office by contributing
### `:void.admin/save` in its own dictionary — and an application that
### composes none still reads English, because this table is the
### fallback rather than a second copy of it.
###
### What is deliberately **not** here: a resource's title and its
### fields' labels. Those words belong to the application's schema, and
### the schema annotates them itself (`:label`, which may be a
### translation key — void/core/text's `label-of`). The admin
### translating a domain noun would be the admin owning a word it did
### not write.
###
### The jobs dashboard keeps the queue's own field names — id, state,
### queue, job, attempt, age, error — untranslated on purpose: they are
### the columns of a record, the same vocabulary `void jobs` prints, and
### an operator matching a log line against a page needs them to be the
### same string.

(import void/core/text)

(def en
  "The admin's words. A plural entry declines by English's rule here
  and by CLDR's once a catalog is bound."
  {# actions and controls
   :void.admin/save "Save"
   :void.admin/cancel "Cancel"
   :void.admin/edit "Edit"
   :void.admin/delete "Delete"
   :void.admin/view "View"
   :void.admin/back-to-list "Back to list"
   :void.admin/search "Search"
   :void.admin/filter "Filter"
   :void.admin/any "any"
   :void.admin/yes "yes"
   :void.admin/no "no"

   # the list
   :void.admin/nothing-here "Nothing here."
   :void.admin/with-selected "With selected:"
   :void.admin/every-matching-row "every row the filter matches"
   :void.admin/new-one "New {singular}"
   :void.admin/add-one "Add {singular}"

   # one row
   :void.admin/one-titled "{singular} {id}"
   :void.admin/edit-titled "Edit {singular} {id}"
   :void.admin/history "History"
   :void.admin/conflict (string "Somebody else saved this row while you were editing it. "
                                "The fields below are theirs — re-apply your change and save again.")

   # confirming a bulk
   :void.admin/confirm-title "{action} — confirm"
   :void.admin/confirm-count {:one "{count} row of {resource} will be affected."
                              :other "{count} rows of {resource} will be affected."}
   :void.admin/cascade-intro "These will go with them:"
   :void.admin/cascade-at-least "at least {count} {label}"
   :void.admin/cascade-exactly "{count} {label}"
   :void.admin/nothing-selected "Nothing is selected, so there is nothing to do."
   :void.admin/confirm-yes "Yes, {action}"

   # a bulk that went to the queue
   :void.admin/running-title "{action} — running"
   :void.admin/job-state "job {id}: {state}"

   # the front page
   :void.admin/at-a-glance "At a glance"

   # the jobs dashboard
   :void.admin/jobs "Jobs"
   :void.admin/jobs-backend "Backend"
   :void.admin/jobs-backlog "Backlog"
   :void.admin/jobs-dead "Dead"
   :void.admin/jobs-enqueued "Enqueued"
   :void.admin/jobs-shared "shared"
   :void.admin/jobs-this-process "this process only"
   :void.admin/jobs-queue "Queue"
   :void.admin/jobs-state "State"
   :void.admin/jobs-job "Job"
   :void.admin/jobs-rows "Rows"
   :void.admin/jobs-all "all"
   :void.admin/jobs-empty "The queue holds nothing."
   :void.admin/jobs-no-record "No record matches."
   :void.admin/jobs-retry "Retry"
   :void.admin/jobs-discard "Discard"
   :void.admin/jobs-retry-all "Retry all"
   :void.admin/jobs-discard-all "Discard all"
   :void.admin/jobs-backend-note "{sharing} · flows {flows} · rate limit {rate} · locks {locks}"
   :void.admin/jobs-dead-note "out of attempts, or killed by hand"
   :void.admin/jobs-enqueued-note "by this process since it started · {duplicates} refused by a unique key"
   :void.admin/jobs-queues "Queues"
   :void.admin/jobs-records "Records"
   :void.admin/jobs-dead-banner {:one "{count} job is dead. "
                                 :other "{count} jobs are dead. "}
   :void.admin/jobs-open-dead "Open the dead letter queue"
   :void.admin/jobs-shown {:one "{count} record shown" :other "{count} records shown"}
   :void.admin/jobs-limited (string " — the first {limit} the backend hands back for this "
                                    "filter. `list` takes a limit and no offset, so there is "
                                    "no page two: ask for more rows above, or narrow the filter")
   :void.admin/jobs-back "Back to the queue"
   :void.admin/jobs-one "Job {id}"
   :void.admin/jobs-failures "Failures"
   :void.admin/jobs-with-every-in-queue "With every {state} record in {queue}:"
   :void.admin/jobs-with-every "With every {state} record in every queue:"
   :void.admin/jobs-nothing-matches "Nothing matches, so there is nothing to do."
   :void.admin/jobs-confirm-title "{action} — confirm"
   :void.admin/jobs-retry-count {:one "{count} {state} record{queue} will go back to the front of the queue with its attempts reset."
                                 :other "{count} {state} records{queue} will go back to the front of the queue with their attempts reset."}
   :void.admin/jobs-discard-count {:one "{count} {state} record{queue} will be dropped. A dropped record is gone: nothing keeps it elsewhere."
                                   :other "{count} {state} records{queue} will be dropped. A dropped record is gone: nothing keeps them elsewhere."}
   :void.admin/jobs-queue-suffix " in queue {queue}"
   :void.admin/jobs-every-queue-suffix " in every queue"
   :void.admin/jobs-confirm-yes {:one "Yes, {action} {count} record"
                                 :other "Yes, {action} {count} records"}
   :void.admin/jobs-gone "the queue no longer holds this job — it finished, or it was never queued"})

(def t
  ``One of the admin's words: `(t :void.admin/save)`,
  `(t :void.admin/new-one {:singular "Note"})`.``
  (text/translator en))
