import QtQuick

// Soft top-down highlight that gives a translucent surface its glass look.
// Drop it in as the first child of a surface and match the surface radius.
Rectangle {
  anchors.fill: parent
  color: "transparent"
  gradient: Gradient {
    GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.10) }
    GradientStop { position: 0.45; color: Qt.rgba(1, 1, 1, 0.03) }
    GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 0.0) }
  }
}
