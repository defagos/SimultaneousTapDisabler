# SimultaneousTapDisabler

A category of UIControl for disabling quasi-simultaneous taps in iOS applications.

This code is licensed under the terms of the BSD License. 

Copyright &copy; 2011, Samuel Défago @ hortis le studio (hortis-le-studio.ch).

### Background

This category allows to set the exclusiveTouch property for all UIControl objects to YES by default, preventing quasi-simultaneous taps.

This behavior will be the default one for UIControl starting with iOS 5

### Use

Simply add the category source files to your project, and insert a call to the HLSEnableUIControlExclusiveTouch() macro into the global scope (main.m or application delegate .m files are the recommended insertion points).
