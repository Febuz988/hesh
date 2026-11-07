from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="HESH_", env_file=".env", extra="ignore")

    database_url: str = "sqlite+aiosqlite:///./hesh.db"
    attachment_dir: str = "./attachments"
    attachment_max_mb: int = 50
    invite_ttl_hours: int = 24
    queue_ttl_days: int = 30
    one_time_prekey_low_watermark: int = 20

    apns_key_path: str = ""
    apns_key_id: str = ""
    apns_team_id: str = ""
    apns_topic: str = "it.hesh.app"
    apns_sandbox: bool = True

    rp_id: str = "hesh.it"
    rp_name: str = "HESH"
    backup_max_mb: int = 5

    @property
    def apns_enabled(self) -> bool:
        return bool(self.apns_key_path and self.apns_key_id and self.apns_team_id)


settings = Settings()
