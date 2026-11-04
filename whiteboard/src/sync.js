// Saves are serialized; a stale tab cannot overwrite a newer phone-side board.
export class BoardSync {
  constructor({ revision, initial, send, status, delay = 700 }) {
    Object.assign(this, { revision, saved: initial, latest: initial, send, status, delay });
    this.timer = null;
    this.running = false;
    this.conflict = false;
  }
  change(scene) {
    this.latest = scene;
    if (scene === this.saved || this.conflict) return;
    this.status('pending');
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.flush(), this.delay);
  }
  flush() {
    clearTimeout(this.timer);
    if (this.inFlight) return this.inFlight;
    if (this.conflict || this.latest === this.saved) return Promise.resolve();
    this.inFlight = this.saveSnapshot().finally(() => { this.inFlight = null; });
    return this.inFlight;
  }
  async saveAll() {
    for (let attempt = 0; attempt < 5; attempt++) {
      await this.flush();
      if (!this.dirty) return true;
      if (this.conflict || this.failed) return false;
    }
    return false;
  }
  async saveSnapshot() {
    this.running = true;
    this.failed = false;
    const snapshot = this.latest;
    this.status('saving');
    try {
      const response = await this.send({ ...JSON.parse(snapshot), revision: this.revision });
      if (response.status === 409) {
        this.conflict = true;
        this.status('conflict');
        return;
      }
      const result = await response.json();
      if (!response.ok) throw new Error(result.error || '保存失败');
      this.revision = result.revision;
      this.saved = snapshot;
      this.status(result.warning ? 'warning' : (this.latest === snapshot ? 'saved' : 'pending'), result.warning || '');
    } catch (error) {
      this.failed = true;
      this.status('error', error.message);
    } finally {
      this.running = false;
      if (!this.conflict && this.latest !== this.saved) {
        clearTimeout(this.timer);
        this.timer = setTimeout(() => this.flush(), 2000);
      }
    }
  }
  acceptRemote(scene, revision) {
    if (this.running || this.dirty || this.conflict || revision <= this.revision) return false;
    clearTimeout(this.timer);
    this.revision = revision;
    this.latest = this.saved = scene;
    this.status('saved');
    return true;
  }
  get dirty() { return this.latest !== this.saved; }
}
