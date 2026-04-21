Pod::Spec.new do |s|
  s.name         = "DualCamera"
  s.version      = "1.0.0"
  s.summary      = "Dual camera module for React Native"
  s.description  = "Native dual camera module using two AVCaptureSessions"
  s.homepage     = "https://github.com/example/DualCamera"
  s.license      = { :type => "MIT" }
  s.author       = { "Author" => "author@example.com" }
  s.platform     = :ios, "13.0"
  s.source       = { :path => "." }
  s.source_files = "*.{h,m}"
  s.frameworks   = "AVFoundation", "UIKit", "Photos"
  s.dependency   "React-Core"
end
