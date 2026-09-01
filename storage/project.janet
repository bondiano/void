(declare-project
  :name "void-storage"
  :description "void/storage — files and uploads: the :void/storage-store contract, a local disk store, an S3-compatible store over void's own HTTP client with SigV4 on void/crypto, temporary URLs, and the form/admin upload seam (ADR-0039).")

# Four plugins in one package, the void/cache — void/cache-http split:
# the kernel and the :local store are plain Janet over the filesystem,
# void/storage-http serves them (void/http), void/storage-s3 signs and
# ships to a bucket (void/http + void/crypto, and void/tls when the
# endpoint is https), void/storage-admin draws the upload widget
# (void/admin) — an application that keeps files on disk loads no
# signer and no widget.
#
# What has to be on the module path is a projection of the package
# graph (scripts/packages.janet, ADR-0020): see test-support/paths.janet.

(declare-source
  :source ["void"])
