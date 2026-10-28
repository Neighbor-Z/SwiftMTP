module gomtp

go 1.21

require (
	github.com/ganeshrvel/go-mtpfs v1.0.4-0.20240426083057-1c3302b3c476
	github.com/ganeshrvel/go-mtpx v0.0.0
	github.com/ganeshrvel/usb v0.0.0-20210103155855-14d96f5ae403
	github.com/json-iterator/go v1.1.12
)

require (
	github.com/modern-go/concurrent v0.0.0-20180228061459-e0a39a4cb421 // indirect
	github.com/modern-go/reflect2 v1.0.2 // indirect
)

replace github.com/ganeshrvel/go-mtpx => ../go-mtpx

replace github.com/ganeshrvel/go-mtpfs => ../go-mtpfs
