# SimultaneousTapDisabler

A category of UIControl for disabling quasi-simultaneous taps in iOS applications.

This code is licensed under the terms of the BSD License. 

Copyright &copy; 2011, Samuel Défago @ hortis le studio (hortis-le-studio.ch).

### Background

In UIKit applications, nothing prevents the user from tapping several controls (quasi) simultaneously. This can lead to ugly side effects when events stack up unexpectedly. One obvious way to avoid several controls to be tapped simultaneously is to introduce boolean variables and check their value, so that no more than one action method can be entered at a time. This task is error-prone and cumbersome, though, especially when lots of controls are involved.

To avoid this issue, the HLSInjection category of UIControl has been written. By adding it to your project, quasi-simultaneous tap events can be disabled with no more than a single line of code.

### Use

Simply add the category source files to your project, and insert a call to the HLSEnableUIControlInjection() macro into the global scope (main.m or application delegate .m files are the recommended insertion points).

### Remark

When you run your application on a device using HLSEnableUIControlInjection(), controls can still be tapped (e.g. several buttons can be highlighted simultaneously), but only one action will be triggered at most.

