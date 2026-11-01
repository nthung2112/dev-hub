# Terminal demo for Dev Hub: the devhub CLI and the JSON dump.
# Install VHS: brew install vhs

Output showcase/demo.gif

Set Shell "zsh"
Set FontSize 18
Set Width 1200
Set Height 700
Set Padding 24
Set WindowBar "ColorfulRight"

Type "cd ~/Documents/Project/dev-hub"
Enter
Sleep 1s

Type "clear"
Enter
Sleep 500ms

Type "echo '>> Dev Hub: local Mac utilities in a notch <<'"
Enter
Sleep 800ms

Type "echo ''"
Enter
Sleep 200ms

Type "echo '[1/2] devhub status'"
Enter
Sleep 1s

Type "./scripts/devhub status"
Enter
Sleep 2s

Type "echo ''"
Enter
Sleep 200ms

Type "echo '[2/2] devhub dump utilities (JSON snapshot)'"
Enter
Sleep 800ms

Type "./scripts/devhub dump utilities | head -18"
Enter
Sleep 3s

Type "clear"
Enter
Sleep 500ms

Type "echo '>> Build and test from source <<'"
Enter
Sleep 800ms

Type "xcrun swift test 2>&1 | tail -4"
Enter
Sleep 12s

Type "echo ''"
Enter
Sleep 300ms

Type "echo '>> Showcase complete.'"
Enter
Sleep 2s
