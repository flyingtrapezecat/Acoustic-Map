from pydantic import BaseModel, ConfigDict


class UpdateRequest(BaseModel):
    # Ignore any extra fields the app sends instead of erroring.
    model_config = ConfigDict(extra="ignore")

    session_id: str | None = None
    lat: float | None = None
    lng: float | None = None
    accuracy_m: float | None = None
    heading_deg: float | None = None
    course_deg: float | None = None
    speed_mps: float | None = None
    timestamp: str | None = None
    transcript: str | None = None
    
class UpdateResponse(BaseModel):
    say: str | None = None
    haptic: str | None = None   # tick, turn_left, turn_right, off_route, arrived
    state: str = "idle"         # idle, listening, thinking, navigating, off_route, arrived
    route: list | None = None        # turn points, sent once per trip
    route_line: list | None = None   # [[lat, lng], ...] the whole walking path, sent with route