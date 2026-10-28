package mtpx

import "os"

var isDev = os.Getenv("APP_ENV") == "development"
