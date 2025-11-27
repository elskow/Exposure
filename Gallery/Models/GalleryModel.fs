namespace Gallery.Models

// Represents a single Roll on the Home Page
type RollSummary = {
    Id: int
    Film: string
    Camera: string
    Lens: string
    Frames: int
    Date: string
}

// Represents a single photo frame on the Roll Detail page
type FrameDetail = {
    Num: int
    IsPortrait: bool
}

// Represents the data needed for the Roll Detail Page
type RollDetailPage = {
    RollId: int
    Film: string
    Camera: string
    Lens: string
    TotalFrames: int
    Keepers: int
    Date: string
    Frames: FrameDetail list
}