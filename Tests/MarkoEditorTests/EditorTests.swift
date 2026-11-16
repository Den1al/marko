import Testing

/// Parent of every suite in this target. The tests run on the main actor and some of them spin the
/// run loop, which would let another one start in the middle; serialized, they run one at a time.
@Suite(.serialized) struct EditorTests {}
