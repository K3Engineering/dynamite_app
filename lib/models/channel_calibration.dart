import 'board_calibration.dart';
import 'load_cell.dart';

/// Everything needed to convert one channel's raw ADC counts into display
/// units: the board piecewise map plus the assigned load cell (if any). Net
/// values are differences of the board map between a reading and the tare
/// point, so piecewise nonlinearity is applied on both sides.
class ChannelCalibration {
  const ChannelCalibration({required this.board, this.loadCell});

  final ChannelBoardCalibration board;

  /// Assigned load cell; null means "electrical units only" — force
  /// conversions report unavailable and the UI shows '—'.
  final LoadCellProfile? loadCell;

  /// Session-snapshot serialization.
  Map<String, dynamic> toJson() => {
    'board': board.toJson(),
    'cell': ?loadCell?.toJson(),
  };

  /// Strict inverse of [toJson]: an absent `cell` key is legal (electrical
  /// units only), but present-but-malformed entries throw
  /// [FormatException] — the caller decides the damage policy (see
  /// SessionStorage.loadSession).
  factory ChannelCalibration.fromJson(Map<String, dynamic> json) {
    final b = json['board'];
    if (b is! Map) {
      throw const FormatException('channel calibration: missing board');
    }
    final c = json['cell'];
    return ChannelCalibration(
      board: ChannelBoardCalibration.fromJson(Map<String, dynamic>.from(b)),
      loadCell: c == null
          ? null
          : LoadCellProfile.fromJson(
              c is Map
                  ? Map<String, dynamic>.from(c)
                  : throw const FormatException(
                      'channel calibration: bad cell',
                    ),
            ),
    );
  }
}
