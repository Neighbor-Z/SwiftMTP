module github.com/ganeshrvel/go-mtpx

go 1.15

require (
	github.com/ganeshrvel/go-mtpfs v1.0.4-0.20240426083057-1c3302b3c476
	github.com/ganeshrvel/usb v0.0.0-20210103155855-14d96f5ae403
	github.com/smartystreets/goconvey v1.6.4
)

// replace github.com/ganeshrvel/go-mtpfs v1.0.4-0.20240426083057-1c3302b3c476 => /<home>/go/src/github.com/ganeshrvel/go-mtpfs

///##### Upgrade a package
//go get github.com/<org-name>/<package-name>@<git-commit-hash>
//example: go get github.com/ganeshrvel/go-mtpfs@<git-commit-hash>
