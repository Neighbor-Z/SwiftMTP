package mtpx

import (
	"github.com/ganeshrvel/go-mtpfs/mtp"
	"os"
)

const PathSep = string(os.PathSeparator)

const ParentObjectId = mtp.GOH_ROOT_PARENT

const devTimeout = 15000

const newLocalDirectoryMode = 0755

const disallowedFileName = ":*?\"<>|"

var disallowedFiles = []string{".DS_Store", "[-----DS_Store.mtp.test----].txt"}

var allowedSecondExtensions allowedSecondExtMap = map[string]string{"tar": "tar"}
