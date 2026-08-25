require "spec"
require "log"

require "../src/config/models"
require "../src/config/usecase"
require "../src/notify/models"
require "../src/notify/repository"
require "../src/notify/usecase"
require "../src/win_notification/models"
require "../src/win_notification/repository"
require "../src/win_notification/usecase"
require "../src/xsoverlay/models"
require "../src/steamvr/usecase"
require "./support/fakes"

Log.setup(:none)
